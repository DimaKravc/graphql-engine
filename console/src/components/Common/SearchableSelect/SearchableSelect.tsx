/* eslint-disable no-param-reassign */
import React, { ReactText } from 'react';
import Select, {
  components,
  createFilter,
  OptionProps,
  OptionTypeBase,
  ValueType,
} from 'react-select';

import { isArray, isObject } from '../utils/jsUtils';

type Option = { label: string; value: string };
/*
 * Wrap the option generated by react-select and adds utility properties
 * */
const CustomOption: React.FC<OptionProps<OptionTypeBase>> = props => {
  return (
    <div
      title={props.data.description || ''}
      data-test={`data_test_column_type_value_${props.data.value}`}
    >
      <components.Option {...props} />
    </div>
  );
};

/*
 * Searchable select box component
 *  1) options: Accepts options
 *  2) value: selectedValue
 *  3) onChange: function to call on change of value
 *  4) bsClass: Wrapper class
 *  5) customStyle: Custom style
 * */
type Props = {
  options: OptionTypeBase | ReactText[];
  onChange: (value: ValueType<OptionTypeBase>) => void;
  value?: Option | string;
  bsClass: string;
  styleOverrides: Record<PropertyKey, any>;
  placeholder: string;
  filterOption: 'prefix' | 'fulltext';
  onInputChange?: (v: string) => void;
  isClearable?: boolean;
  onMenuClose?: () => void;
};
const SearchableSelectBox: React.FC<Props> = ({
  options,
  onChange,
  value,
  bsClass,
  styleOverrides,
  placeholder,
  filterOption,
  onInputChange,
  onMenuClose,
}) => {
  /* Select element style customization */

  const customStyles: Record<string, any> = {};
  if (styleOverrides) {
    Object.keys(styleOverrides).forEach(comp => {
      customStyles[comp] = (provided: object) => ({
        ...provided,
        ...styleOverrides[comp],
      });
    });
  }

  let customFilter;
  switch (filterOption) {
    case 'prefix':
      customFilter = createFilter({ matchFrom: 'start' });
      break;
    case 'fulltext':
      customFilter = createFilter({ matchFrom: 'any' });
      break;
    default:
      customFilter = null;
  }

  // handle simple options
  if (isArray(options) && !isObject(options[0])) {
    options = options.map(op => {
      return { value: op, label: op };
    });
  }

  if (value && !isObject(value)) {
    value = { value, label: value };
  }

  return (
    <Select
      isSearchable
      components={{ Option: CustomOption }}
      classNamePrefix={bsClass}
      placeholder={placeholder}
      options={options as Option[]}
      onChange={onChange}
      value={value as Option}
      styles={customStyles}
      filterOption={customFilter}
      onInputChange={onInputChange}
      onMenuClose={onMenuClose}
    />
  );
};

export default SearchableSelectBox;
