///|
test "autoincrement primary key renders AUTOINCREMENT" {
  assert_eq(
    column("id", IntType, primary_key=true, autoincrement=true).ddl(),
    "id INTEGER PRIMARY KEY AUTOINCREMENT",
  )
  // Not emitted without a primary key.
  assert_eq(column("n", IntType, autoincrement=true).ddl(), "n INTEGER")
}
