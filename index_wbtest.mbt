///|
test "index_ddl renders single, composite, and unique indexes" {
  assert_eq(
    index_ddl("idx_email", "users", ["email"], unique=true),
    "CREATE UNIQUE INDEX idx_email ON users (email)",
  )
  assert_eq(
    index_ddl("idx_name_age", "users", ["name", "age"]),
    "CREATE INDEX idx_name_age ON users (name, age)",
  )
}
