///|
test "extended column types render their declared SQL type" {
  assert_eq(column("name", VarcharType(255)).ddl(), "name VARCHAR(255)")
  assert_eq(column("price", NumericType).ddl(), "price NUMERIC")
  assert_eq(column("created", DateTimeType).ddl(), "created DATETIME")
  assert_eq(column("d", DateType).ddl(), "d DATE")
  assert_eq(column("t", TimeType).ddl(), "t TIME")
  // UUID / JSON store as TEXT on SQLite.
  assert_eq(column("uid", UuidType).ddl(), "uid TEXT")
  assert_eq(column("doc", JsonType).ddl(), "doc TEXT")
}
