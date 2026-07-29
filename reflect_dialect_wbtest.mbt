///|
fn pg_row(name : String, ty : String, nullable : String) -> @moondb.Row {
  {
    columns: ["column_name", "data_type", "is_nullable"],
    values: [@moondb.Text(name), @moondb.Text(ty), @moondb.Text(nullable)],
  }
}

///|
fn my_row(
  field : String,
  ty : String,
  null_ : String,
  key : String,
  extra : String,
) -> @moondb.Row {
  {
    columns: ["Field", "Type", "Null", "Key", "Default", "Extra"],
    values: [
      @moondb.Text(field),
      @moondb.Text(ty),
      @moondb.Text(null_),
      @moondb.Text(key),
      @moondb.Text(""),
      @moondb.Text(extra),
    ],
  }
}

///|
test "reflect_columns_pg parses information_schema.columns" {
  let cols = reflect_columns_pg([
    pg_row("id", "integer", "NO"),
    pg_row("flag", "boolean", "NO"),
    pg_row("doc", "jsonb", "YES"),
    pg_row("created", "timestamp without time zone", "YES"),
  ])
  assert_eq(cols.length(), 4)
  assert_eq(cols[0].name, "id")
  assert_eq(cols[0].nullable, false)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].col_type == BoolType, true)
  assert_eq(cols[2].col_type == JsonType, true)
  assert_eq(cols[3].col_type == DateTimeType, true)
}

///|
test "reflect_columns_mysql parses SHOW COLUMNS with key and auto_increment" {
  let cols = reflect_columns_mysql([
    my_row("id", "int", "NO", "PRI", "auto_increment"),
    my_row("active", "tinyint(1)", "YES", "", ""),
    my_row("name", "varchar(100)", "NO", "", ""),
  ])
  assert_eq(cols[0].primary_key, true)
  assert_eq(cols[0].autoincrement, true)
  assert_eq(cols[0].col_type == IntType, true)
  assert_eq(cols[1].col_type == BoolType, true)
  assert_eq(cols[1].primary_key, false)
  assert_eq(cols[2].col_type == TextType, true)
}
