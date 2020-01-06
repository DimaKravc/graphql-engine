module Hasura.RQL.DDL.ScheduledTrigger
  ( runCreateScheduledTrigger
  ) where

import           Hasura.Db
import           Hasura.EncJSON
import           Hasura.Prelude
import           Hasura.RQL.DDL.Schema.Cache       (CacheBuildM)
import           Hasura.RQL.DDL.EventTrigger ( getWebhookInfoFromConf
                                             , getHeaderInfosFromConf)
import           Hasura.RQL.Types.Helpers
import           Hasura.RQL.Types.ScheduledTrigger
import           Hasura.RQL.Types.SchemaCache ( addScheduledTriggerToCache
                                              , ScheduledTriggerInfo(..))

import qualified Data.Aeson            as J
import qualified Database.PG.Query     as Q

runCreateScheduledTrigger :: CacheBuildM m => CreateScheduledTrigger ->  m EncJSON
runCreateScheduledTrigger q = do
  sti <- addScheduledTriggerSetup q
  addScheduledTriggerToCatalog q
  addScheduledTriggerToCache sti
  return successMsg

addScheduledTriggerToCatalog :: CacheBuildM m => CreateScheduledTrigger ->  m ()
addScheduledTriggerToCatalog CreateScheduledTrigger {..} = liftTx $
  Q.unitQE defaultTxErrorHandler
  [Q.sql|
    INSERT into hdb_catalog.hdb_scheduled_trigger
                (name, webhook_conf, schedule, payload, retry_conf)
    VALUES ($1, $2, $3, $4, $5)
  |] (stName, Q.AltJ $ J.toJSON stWebhookConf, Q.AltJ stSchedule, Q.AltJ <$> stPayload, Q.AltJ stRetryConf) False

addScheduledTriggerSetup ::
     (CacheBuildM m) => CreateScheduledTrigger -> m ScheduledTriggerInfo
addScheduledTriggerSetup CreateScheduledTrigger {..} = do
  let headerConfs = fromMaybe [] stHeaders
  webhookInfo <- getWebhookInfoFromConf stWebhookConf
  headerInfo <- getHeaderInfosFromConf headerConfs
  let stInfo =
        ScheduledTriggerInfo
          stName
          stSchedule
          stPayload
          stRetryConf
          webhookInfo
          headerInfo
  pure stInfo
