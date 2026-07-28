///|
test "select: columns, where, order, limit — parameterized" {
  let (sql, params) = select("users")
    .column("id")
    .column("name")
    .eq("age", Int(18))
    .where_("name", "LIKE", Text("bob%"))
    .order_by("name", Asc)
    .limit(10)
    .build()
  assert_eq(
    sql, "SELECT id, name FROM users WHERE age = ? AND name LIKE ? ORDER BY name ASC LIMIT 10",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(18), true)
  assert_eq(params[1] == Text("bob%"), true)
}

///|
test "select: star projection and offset" {
  let (sql, _) = select("t").limit(5).offset(10).build()
  assert_eq(sql, "SELECT * FROM t LIMIT 5 OFFSET 10")
}

///|
test "insert" {
  let (sql, params) = insert("users")
    .set("name", Text("bob"))
    .set("age", Int(30))
    .build()
  assert_eq(sql, "INSERT INTO users (name, age) VALUES (?, ?)")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("bob"), true)
}

///|
test "update" {
  let (sql, params) = update("users")
    .set("age", Int(31))
    .where_("id", "=", Int(1))
    .build()
  assert_eq(sql, "UPDATE users SET age = ? WHERE id = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(31), true)
  assert_eq(params[1] == Int(1), true)
}

///|
test "delete" {
  let (sql, params) = delete("users").where_("id", "=", Int(9)).build()
  assert_eq(sql, "DELETE FROM users WHERE id = ?")
  assert_eq(params.length(), 1)
}

///|
test "injection-safe: a value is never spliced into the SQL string" {
  let evil = "'; DROP TABLE users; --"
  let (sql, params) = select("users").eq("name", Text(evil)).build()
  assert_eq(sql, "SELECT * FROM users WHERE name = ?")
  assert_eq(params[0] == Text(evil), true)
}
