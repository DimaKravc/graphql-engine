type TableSchema = {
  primary_key?: { columns: string[] };
  columns: Array<{ column_name: string }>;
};

type TableSchemaWithPK = {
  [P in keyof TableSchema]-?: TableSchema[P];
};

export const checkIfHasPrimaryKey = (tableSchema: {
  primary_key?: { columns: string[] };
}): tableSchema is TableSchemaWithPK => {
  return (
    tableSchema.primary_key !== undefined &&
    tableSchema.primary_key.columns.length > 0
  );
};

export const compareRows = (
  row1: Record<string, any>,
  row2: Record<string, any>,
  tableSchema: TableSchema,
  isView: boolean
) => {
  const hasPrimaryKey = checkIfHasPrimaryKey(tableSchema);
  let same = true;
  if (!isView && hasPrimaryKey && checkIfHasPrimaryKey(tableSchema)) {
    tableSchema.primary_key.columns.forEach(pk => {
      if (row1[pk] !== row2[pk]) {
        same = false;
      }
    });
    return same;
  }
  tableSchema.columns.forEach(k => {
    if (row1[k.column_name] !== row2[k.column_name]) {
      same = false;
    }
  });
  return same;
};
