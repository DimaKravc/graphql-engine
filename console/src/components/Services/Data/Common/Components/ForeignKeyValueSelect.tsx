import React, {
  useState,
  useEffect,
  useRef,
  useMemo,
  ComponentProps,
} from 'react';
import throttle from 'lodash.throttle';

import styles from '../../../../Common/TableCommon/Table.scss';
import SearchableSelect from '../../../../Common/SearchableSelect/SearchableSelect';

const searchableSelectStyles = {
  container: {
    width: '270px',
  },
  control: {
    minHeight: '34px',
  },
  dropdownIndicator: {
    padding: '5px',
  },
  valueContainer: {
    padding: '0px 12px',
  },
};

const createOpt = (prevValue: string) => ({
  value: prevValue,
  label: prevValue,
});

type Option = { label: string; value: string };

type FkColOption = {
  from: string;
  to: string;
  displayName: string;
  data: Array<Record<string, string>>;
};

type Props = {
  prevValue: string;
  fkOptions: Array<FkColOption>;
  getFkOptions: (opts: FkColOption, value: string) => Promise<void>;
  onFkValueChange: ComponentProps<typeof SearchableSelect>['onChange'];
  selectedOption: Option;
  standardInputProps: ComponentProps<'select'>;
  placeholder: string; // TODO
  columnName: string;
};

export const ForeignKeyValueSelect: React.FC<Props> = ({
  prevValue,
  fkOptions,
  getFkOptions,
  onFkValueChange,
  selectedOption,
  standardInputProps,
  columnName,
  placeholder,
}) => {
  const [searchValue, setSearchValue] = useState('');

  const columnFkOpts = useRef<FkColOption>();
  columnFkOpts.current =
    fkOptions && fkOptions.find(opts => opts.from === columnName);

  const getForeignKeyOptionsThrottled = useMemo(
    () =>
      throttle(
        (value: string) =>
          columnFkOpts.current && getFkOptions(columnFkOpts.current, value),
        1000
      ),
    [getFkOptions]
  );

  useEffect(() => {
    if (columnFkOpts) {
      getForeignKeyOptionsThrottled(searchValue);
    }
  }, [searchValue]);

  const onMenuClose = () => {
    if (searchValue !== '') onFkValueChange(createOpt(searchValue));
  };

  let options = columnFkOpts.current
    ? columnFkOpts.current.data.map(row => ({
      label: `${row[columnFkOpts.current!.displayName]} (${
        row[columnFkOpts.current!.to]
      })`,
      value: row[columnFkOpts.current!.to],
    }))
    : [];

  // Creating new option based on input
  if (searchValue !== '') {
    options = [createOpt(searchValue), ...options];
  }

  const getValue = () => {
    if (!selectedOption) {
      return prevValue ? createOpt(prevValue) : undefined;
    }
    return selectedOption;
  };

  return (
    <SearchableSelect
      {...standardInputProps}
      isClearable
      options={options}
      onChange={onFkValueChange}
      value={getValue()}
      bsClass={styles.insertBox}
      styleOverrides={searchableSelectStyles}
      onInputChange={(v: string) => setSearchValue(v)}
      filterOption="fulltext"
      // Treating last search value the same was as selected option,
      // so that user don't have to click in the dropdown, they can just leave the input
      onMenuClose={onMenuClose}
      placeholder={placeholder}
    />
  );
};
