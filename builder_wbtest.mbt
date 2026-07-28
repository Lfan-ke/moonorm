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

///|
test "select: join + group_by + having, clause order and params" {
  let (sql, params) = select("orders")
    .raw("users.name")
    .count()
    .join("users", "users.id = orders.user_id")
    .left_join("regions", "regions.id = users.region_id")
    .eq("orders.status", Text("paid"))
    .group_by("users.name")
    .having("COUNT(*)", ">", Int(3))
    .order_by("users.name", Asc)
    .limit(20)
    .build()
  assert_eq(
    sql, "SELECT users.name, COUNT(*) FROM orders JOIN users ON users.id = orders.user_id LEFT JOIN regions ON regions.id = users.region_id WHERE orders.status = ? GROUP BY users.name HAVING COUNT(*) > ? ORDER BY users.name ASC LIMIT 20",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("paid"), true)
  assert_eq(params[1] == Int(3), true)
}

///|
test "select: multiple group_by columns and count aggregate" {
  let (sql, _) = select("sales")
    .column("region")
    .column("year")
    .count()
    .group_by("region")
    .group_by("year")
    .build()
  assert_eq(
    sql, "SELECT region, year, COUNT(*) FROM sales GROUP BY region, year",
  )
}

///|
test "having stays parameterized (injection-safe)" {
  let evil = "0 OR 1=1"
  let (sql, params) = select("t")
    .count()
    .group_by("g")
    .having("SUM(x)", ">", Text(evil))
    .build()
  assert_eq(sql, "SELECT COUNT(*) FROM t GROUP BY g HAVING SUM(x) > ?")
  assert_eq(params[0] == Text(evil), true)
}

///|
test "Table descriptor: select() projects all declared columns" {
  let users : Table = { name: "users", columns: ["id", "name", "age"] }
  let (sql, _) = users.select().eq("age", Int(18)).build()
  assert_eq(sql, "SELECT id, name, age FROM users WHERE age = ?")
}

///|
test "Table descriptor: empty columns yields SELECT *" {
  let t : Table = { name: "logs", columns: [] }
  let (sql, _) = t.select().build()
  assert_eq(sql, "SELECT * FROM logs")
}
