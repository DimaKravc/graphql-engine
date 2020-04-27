{-|
= Scheduled Triggers

This module implements the functionality of invoking webhooks during specified
time events aka scheduled events. The scheduled events are the events generated
by the graphql-engine using the scheduled-triggers. Scheduled events are modeled
using rows in Postgres with a @timestamp@ column.

This module implements scheduling and delivery of scheduled events:

1. Scheduling a scheduled event involves creating new scheduled events using the
parameters of the scheduled trigger (cron schedule, webhook url, payload
and headers).

2. Delivering a scheduled event involves fetching undelivered scheduled events from
the database and delivering them to the webhook server.

== Implementation

During the startup, a single thread is started. The thread does two things
as mentioned below:

1. Fetch the list of scheduled triggers from cache and generate the
   scheduled events.

    - Additional events will be generated only if there are fewer than 100
      scheduled events.

    - The upcoming events timestamp will be generated using:

        - cron schedule of the scheduled trigger

        - max timestamp of the scheduled events that already exist or
          current_timestamp(when no scheduled events exist)

        - The timestamp of the scheduled events is stored with timezone because
          `SELECT NOW()` returns timestamp with timezone, so it's good to
          compare two things of the same type.

    This effectively corresponds to doing an INSERT with values containing
    specific timestamp.

2. Fetch the undelivered events from the database and which have the scheduled
   timestamp lesser than the current timestamp and then process them.
-}
module Hasura.Eventing.ScheduledTrigger
  ( scheduledTriggersRunner
  , ScheduledEventSeed(..)
  , generateScheduleTimes
  , insertScheduledEvents
  ) where

import           Control.Arrow.Extended            (dup)
import           Control.Concurrent.Extended       (sleep)
import           Data.Has
import           Data.Int                          (Int64)
import           Data.List                         (unfoldr)
import           Data.Time.Clock
import           Hasura.Eventing.HTTP
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.Server.Version             (HasVersion)
import           Hasura.SQL.DML
import           Hasura.SQL.Types
import           System.Cron

import qualified Data.Aeson                        as J
import qualified Data.Aeson.Casing                 as J
import qualified Data.Aeson.TH                     as J
import qualified Data.HashMap.Strict               as Map
import qualified Data.TByteString                  as TBS
import qualified Data.Text                         as T
import qualified Database.PG.Query                 as Q
import qualified Hasura.Logging                    as L
import qualified Network.HTTP.Client               as HTTP
import qualified Text.Builder                      as TB (run)

newtype ScheduledTriggerInternalErr
  = ScheduledTriggerInternalErr QErr
  deriving (Show, Eq)

instance L.ToEngineLog ScheduledTriggerInternalErr L.Hasura where
  toEngineLog (ScheduledTriggerInternalErr qerr) =
    (L.LevelError, L.scheduledTriggerLogType, J.toJSON qerr)

scheduledEventsTable :: QualifiedTable
scheduledEventsTable =
  QualifiedObject
    hdbCatalogSchema
    (TableName $ T.pack "hdb_scheduled_events")

data ScheduledTriggerStats
  = ScheduledTriggerStats
  { stsName                :: !TriggerName
  , stsUpcomingEventsCount :: !Int
  , stsMaxScheduledTime    :: !UTCTime
  } deriving (Show, Eq)

data ScheduledEventSeed
  = ScheduledEventSeed
  { sesName          :: !TriggerName
  , sesScheduledTime :: !UTCTime
  } deriving (Show, Eq)

data ScheduledEventPartial
  = ScheduledEventPartial
  { sepId            :: !Text
  , sepName          :: !TriggerName
  , sepScheduledTime :: !UTCTime
  , sepPayload       :: !(Maybe J.Value)
  , sepTries         :: !Int
  } deriving (Show, Eq)

data ScheduledEventFull
  = ScheduledEventFull
  { sefId            :: !Text
  , sefName          :: !TriggerName
  , sefScheduledTime :: !UTCTime
  , sefTries         :: !Int
  , sefWebhook       :: !T.Text
  , sefPayload       :: !J.Value
  , sefRetryConf     :: !STRetryConf
  } deriving (Show, Eq)

$(J.deriveToJSON (J.aesonDrop 3 J.snakeCase) {J.omitNothingFields = True} ''ScheduledEventFull)

-- | runScheduledEventsGenerator makes sure that all the scheduled triggers
--   have an adequate buffer of scheduled events.
runScheduledEventsGenerator ::
     L.Logger L.Hasura
  -> Q.PGPool
  -> IO SchemaCache
  -> IO ()
runScheduledEventsGenerator logger pgpool getSC = do
  sc <- getSC
  -- get scheduled triggers from cache
  let scheduledTriggersCache = scScheduledTriggers sc
   -- get scheduled trigger stats from db
  runExceptT
    (Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadOnly) getDeprivedScheduledTriggerStats) >>= \case
    Left err -> L.unLogger logger $
      ScheduledTriggerInternalErr $ err500 Unexpected (T.pack $ show err)
    Right deprivedScheduledTriggerStats -> do
      -- join stats with scheduled triggers and produce @[(ScheduledTriggerInfo, ScheduledTriggerStats)]@
      --scheduledTriggersForHydrationWithStats' <- mapM (withST scheduledTriggers) deprivedScheduledTriggerStats
      scheduledTriggersForHydrationWithStats <-
        catMaybes <$>
        mapM (withST scheduledTriggersCache) deprivedScheduledTriggerStats
      -- insert scheduled events for scheduled triggers that need hydration
      runExceptT
        (Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) $
        insertScheduledEventsFor scheduledTriggersForHydrationWithStats) >>= \case
        Right _ -> pure ()
        Left err ->
          L.unLogger logger $ ScheduledTriggerInternalErr $ err500 Unexpected (T.pack $ show err)
  where
    getDeprivedScheduledTriggerStats = liftTx $ do
      map uncurryStats <$>
        Q.listQE defaultTxErrorHandler
        [Q.sql|
         SELECT name, upcoming_events_count, max_scheduled_time
         FROM hdb_catalog.hdb_scheduled_events_stats
         WHERE upcoming_events_count < 100
        |] () True

    uncurryStats (n, count, maxTs) = ScheduledTriggerStats n count maxTs

    withST scheduledTriggerCache scheduledTriggerStat = do
      case Map.lookup (stsName scheduledTriggerStat) scheduledTriggerCache of
        Nothing -> do
          L.unLogger logger $
            ScheduledTriggerInternalErr $
              err500 Unexpected $
                "could not find scheduled trigger in the schema cache"
          pure Nothing
        Just scheduledTrigger -> pure $
          Just (scheduledTrigger, scheduledTriggerStat)

insertScheduledEventsFor :: [(ScheduledTriggerInfo, ScheduledTriggerStats)] -> Q.TxE QErr ()
insertScheduledEventsFor scheduledTriggersWithStats = do
  let scheduledEvents = flip concatMap scheduledTriggersWithStats $ \(sti, stats) ->
        generateScheduledEventsFrom (stsMaxScheduledTime stats) sti
  case scheduledEvents of
    []     -> pure ()
    events -> do
      let insertScheduledEventsSql = TB.run $ toSQL
            SQLInsert
              { siTable    = scheduledEventsTable
              , siCols     = map unsafePGCol ["name", "scheduled_time"]
              , siValues   = ValuesExp $ map (toTupleExp . toArr) events
              , siConflict = Just $ DoNothing Nothing
              , siRet      = Nothing
              }
      Q.unitQE defaultTxErrorHandler (Q.fromText insertScheduledEventsSql) () False
  where
    toArr (ScheduledEventSeed n t) = [(triggerNameToTxt n), (formatTime' t)]
    toTupleExp = TupleExp . map SELit

insertScheduledEvents :: [ScheduledEventSeed] -> Q.TxE QErr ()
insertScheduledEvents events = do
  let insertScheduledEventsSql = TB.run $ toSQL
        SQLInsert
          { siTable    = scheduledEventsTable
          , siCols     = map unsafePGCol ["name", "scheduled_time"]
          , siValues   = ValuesExp $ map (toTupleExp . toArr) events
          , siConflict = Just $ DoNothing Nothing
          , siRet      = Nothing
          }
  Q.unitQE defaultTxErrorHandler (Q.fromText insertScheduledEventsSql) () False
  where
    toArr (ScheduledEventSeed n t) = [(triggerNameToTxt n), (formatTime' t)]
    toTupleExp = TupleExp . map SELit

generateScheduledEventsFrom :: UTCTime -> ScheduledTriggerInfo-> [ScheduledEventSeed]
generateScheduledEventsFrom startTime ScheduledTriggerInfo{..} =
  let events =
        case stiSchedule of
          AdHoc _   -> empty -- ad-hoc scheduled events are created through 'create_scheduled_event' API
          Cron cron -> generateScheduleTimes startTime 100 cron -- by default, generate next 100 events
   in map (ScheduledEventSeed stiName) events

-- | Generates next @n events starting @from according to 'CronSchedule'
generateScheduleTimes :: UTCTime -> Int -> CronSchedule -> [UTCTime]
generateScheduleTimes from n cron = take n $ go from
  where
    go = unfoldr (fmap dup . nextMatch cron)

processScheduledQueue
  :: HasVersion
  => L.Logger L.Hasura
  -> LogEnvHeaders
  -> HTTP.Manager
  -> Q.PGPool
  -> IO SchemaCache
  -> IO ()
processScheduledQueue logger logEnv httpMgr pgpool getSC = do
  scheduledTriggersInfo <- scScheduledTriggers <$> getSC
  scheduledEventsE <-
    runExceptT $
    Q.runTx pgpool (Q.ReadCommitted, Just Q.ReadWrite) getScheduledEvents
  case scheduledEventsE of
    Right partialEvents ->
      for_ partialEvents $ \(ScheduledEventPartial id' name st payload tries)-> do
        case Map.lookup name scheduledTriggersInfo of
          Nothing ->  logInternalError $
            err500 Unexpected "could not find scheduled trigger in cache"
          Just stInfo@ScheduledTriggerInfo{..} -> do
            let webhook = wciCachedValue stiWebhookInfo
                payload' = fromMaybe (fromMaybe J.Null stiPayload) payload -- override if neccessary
                scheduledEvent = ScheduledEventFull id' name st tries webhook payload' stiRetryConf
            finally <- runExceptT $
              runReaderT (processScheduledEvent logEnv pgpool stInfo scheduledEvent) (logger, httpMgr)
            either logInternalError pure finally
    Left err -> logInternalError err
  where
    logInternalError err = L.unLogger logger $ ScheduledTriggerInternalErr err

scheduledTriggersRunner
  :: HasVersion
  => L.Logger L.Hasura
  -> LogEnvHeaders
  -> HTTP.Manager
  -> Q.PGPool
  -> IO SchemaCache
  -> IO void
scheduledTriggersRunner logger logEnv httpMgr pgPool getSC =
  forever $ do
  runScheduledEventsGenerator logger pgPool getSC
  processScheduledQueue logger logEnv httpMgr pgPool getSC
  sleep (minutes 1)

processScheduledEvent ::
  ( MonadReader r m
  , Has HTTP.Manager r
  , Has (L.Logger L.Hasura) r
  , HasVersion
  , MonadIO m
  , MonadError QErr m
  )
  => LogEnvHeaders
  -> Q.PGPool
  -> ScheduledTriggerInfo
  -> ScheduledEventFull
  -> m ()
processScheduledEvent
  logEnv pgpool ScheduledTriggerInfo {..} se@ScheduledEventFull {..} = do
  currentTime <- liftIO getCurrentTime
  if convertDuration (diffUTCTime currentTime sefScheduledTime)
    > unNonNegativeDiffTime (strcToleranceSeconds stiRetryConf)
    then processDead pgpool se
    else do
      let timeoutSeconds = round $ unNonNegativeDiffTime
                             $ strcTimeoutSeconds stiRetryConf
          httpTimeout = HTTP.responseTimeoutMicro (timeoutSeconds * 1000000)
          headers = addDefaultHeaders $ map encodeHeader stiHeaders
          extraLogCtx = ExtraLogContext (Just currentTime) sefId
      res <- runExceptT $ tryWebhook headers httpTimeout sefPayload (T.unpack sefWebhook)
      logHTTPForST res extraLogCtx
      let decodedHeaders = map (decodeHeader logEnv stiHeaders) headers
      either
        (processError pgpool se decodedHeaders)
        (processSuccess pgpool se decodedHeaders)
        res

processError
  :: (MonadIO m, MonadError QErr m)
  => Q.PGPool -> ScheduledEventFull -> [HeaderConf] -> HTTPErr a -> m ()
processError pgpool se decodedHeaders err = do
  let invocation = case err of
        HClient excp -> do
          let errMsg = TBS.fromLBS $ J.encode $ show excp
          mkInvocation se 1000 decodedHeaders errMsg []
        HParse _ detail -> do
          let errMsg = TBS.fromLBS $ J.encode detail
          mkInvocation se 1001 decodedHeaders errMsg []
        HStatus errResp -> do
          let respPayload = hrsBody errResp
              respHeaders = hrsHeaders errResp
              respStatus = hrsStatus errResp
          mkInvocation se respStatus decodedHeaders respPayload respHeaders
        HOther detail -> do
          let errMsg = (TBS.fromLBS $ J.encode detail)
          mkInvocation se 500 decodedHeaders errMsg []
  liftExceptTIO $
    Q.runTx pgpool (Q.RepeatableRead, Just Q.ReadWrite) $ do
    insertInvocation invocation
    retryOrMarkError se err

retryOrMarkError :: ScheduledEventFull -> HTTPErr a -> Q.TxE QErr ()
retryOrMarkError se@ScheduledEventFull {..} err = do
  let mRetryHeader = getRetryAfterHeaderFromHTTPErr err
      mRetryHeaderSeconds = parseRetryHeaderValue =<< mRetryHeader
      triesExhausted = sefTries >= strcNumRetries sefRetryConf
      noRetryHeader = isNothing mRetryHeaderSeconds
  if triesExhausted && noRetryHeader
    then do
      markError
    else do
      currentTime <- liftIO getCurrentTime
      let delay = fromMaybe (round $ unNonNegativeDiffTime
                             $ strcRetryIntervalSeconds sefRetryConf)
                    $ mRetryHeaderSeconds
          diff = fromIntegral delay
          retryTime = addUTCTime diff currentTime
      setRetry se retryTime
  where
    markError =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
        UPDATE hdb_catalog.hdb_scheduled_events
        SET error = 't', locked = 'f'
        WHERE id = $1
      |] (Identity sefId) True

{- Note [Scheduled event lifecycle]

A scheduled event can be in one of the five following states at any time:

1. Delivered
2. Cancelled
3. Error
4. Locked
5. Dead

A scheduled event is marked as delivered when the scheduled event is processed
successfully.

A scheduled event is marked as error when while processing the scheduled event
the webhook returns an error and the retries have exhausted (user configurable)
it's marked as error.

A scheduled event will be in the locked state when the graphql-engine fetches it
from the database to process it. After processing the event, the graphql-engine
will unlock it. This state is used to prevent multiple graphql-engine instances
running on the same database to process the same event concurrently.

A scheduled event will be marked as dead, when the difference between the
current time and the scheduled time is greater than the tolerance of the event.

A scheduled event will be in the cancelled state, if the `cancel_scheduled_event`
API is called against a particular scheduled event.

The graphql-engine will not consider those events which have been delivered,
cancelled, marked as error or in the dead state to process.
-}

processSuccess
  :: (MonadIO m, MonadError QErr m)
  => Q.PGPool -> ScheduledEventFull -> [HeaderConf] -> HTTPResp a -> m ()
processSuccess pgpool se decodedHeaders resp = do
  let respBody = hrsBody resp
      respHeaders = hrsHeaders resp
      respStatus = hrsStatus resp
      invocation = mkInvocation se respStatus decodedHeaders respBody respHeaders
  liftExceptTIO $
    Q.runTx pgpool (Q.RepeatableRead, Just Q.ReadWrite) $ do
    insertInvocation invocation
    markSuccess
  where
    markSuccess =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
        UPDATE hdb_catalog.hdb_scheduled_events
        SET delivered = 't', locked = 'f'
        WHERE id = $1
      |] (Identity $ sefId se) True

processDead :: (MonadIO m, MonadError QErr m) => Q.PGPool -> ScheduledEventFull -> m ()
processDead pgpool se =
  liftExceptTIO $
  Q.runTx pgpool (Q.RepeatableRead, Just Q.ReadWrite) markDead
  where
    markDead =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET dead = 't', locked = 'f'
          WHERE id = $1
        |] (Identity $ sefId se) False

setRetry :: ScheduledEventFull -> UTCTime -> Q.TxE QErr ()
setRetry se time =
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET next_retry_at = $1, locked = 'f'
          WHERE id = $2
          |] (time, sefId se) True

mkInvocation
  :: ScheduledEventFull -> Int -> [HeaderConf] -> TBS.TByteString -> [HeaderConf]
  -> (Invocation 'ScheduledType)
mkInvocation se status reqHeaders respBody respHeaders
  = let resp = if isClientError status
          then mkClientErr respBody
          else mkResp status respBody respHeaders
    in
      Invocation
      (sefId se)
      status
      (mkWebhookReq (J.toJSON se) reqHeaders invocationVersionST)
      resp

insertInvocation :: (Invocation 'ScheduledType) -> Q.TxE QErr ()
insertInvocation invo = do
  Q.unitQE defaultTxErrorHandler [Q.sql|
          INSERT INTO hdb_catalog.hdb_scheduled_event_invocation_logs
          (event_id, status, request, response)
          VALUES ($1, $2, $3, $4)
          |] ( iEventId invo
             , fromIntegral $ iStatus invo :: Int64
             , Q.AltJ $ J.toJSON $ iRequest invo
             , Q.AltJ $ J.toJSON $ iResponse invo) True
  Q.unitQE defaultTxErrorHandler [Q.sql|
          UPDATE hdb_catalog.hdb_scheduled_events
          SET tries = tries + 1
          WHERE id = $1
          |] (Identity $ iEventId invo) True

getScheduledEvents :: Q.TxE QErr [ScheduledEventPartial]
getScheduledEvents = do
  map uncurryEvent <$> Q.listQE defaultTxErrorHandler [Q.sql|
      UPDATE hdb_catalog.hdb_scheduled_events
      SET locked = 't'
      WHERE id IN ( SELECT t.id
                    FROM hdb_catalog.hdb_scheduled_events t
                    WHERE ( t.locked = 'f'
                            and t.cancelled = 'f'
                            and t.delivered = 'f'
                            and t.error = 'f'
                            and (
                             (t.next_retry_at is NULL and t.scheduled_time <= now()) or
                             (t.next_retry_at is not NULL and t.next_retry_at <= now())
                            )
                            and t.dead = 'f'
                          )
                    FOR UPDATE SKIP LOCKED
                    )
      RETURNING id, name, scheduled_time, additional_payload, tries
      |] () True
  where uncurryEvent (i, n, st, p, tries) = ScheduledEventPartial i n st (Q.getAltJ <$> p) tries

liftExceptTIO :: (MonadError e m, MonadIO m) => ExceptT e IO a -> m a
liftExceptTIO m = liftEither =<< liftIO (runExceptT m)
