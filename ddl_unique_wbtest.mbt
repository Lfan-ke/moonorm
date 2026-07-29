///|
test "Column::ddl emits UNIQUE for a unique non-key column" {
  assert_eq(
    column("email", TextType, nullable=false, unique=true).ddl(),
    "email TEXT NOT NULL UNIQUE",
  )
  // A primary key is already unique, so UNIQUE is not re-emitted.
  assert_eq(
    column("id", IntType, primary_key=true, unique=true).ddl(),
    "id INTEGER PRIMARY KEY",
  )
  // Plain nullable unique column.
  assert_eq(column("slug", TextType, unique=true).ddl(), "slug TEXT UNIQUE")
}
