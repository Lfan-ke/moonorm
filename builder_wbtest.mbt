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

///|
test "window: ROW_NUMBER with PARTITION BY and ORDER BY, aliased" {
  let (sql, params) = select("emp")
    .column("name")
    .window(
      "ROW_NUMBER()",
      partition_by=["dept"],
      order_by=[("salary", Desc)],
      as_="rn",
    )
    .build()
  assert_eq(
    sql, "SELECT name, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn FROM emp",
  )
  assert_eq(params.length(), 0)
}

///|
test "window: multi-column partition and order, running aggregate, no alias" {
  let (sql, _) = select("sales")
    .window("SUM(amount)", partition_by=["region", "year"], order_by=[
      ("month", Asc),
    ])
    .build()
  assert_eq(
    sql, "SELECT SUM(amount) OVER (PARTITION BY region, year ORDER BY month ASC) FROM sales",
  )
}

///|
test "window: empty partition and order yields OVER ()" {
  let (sql, _) = select("t").window("COUNT(*)", as_="total").build()
  assert_eq(sql, "SELECT COUNT(*) OVER () AS total FROM t")
}

///|
test "window: coexists with a real WHERE that still binds its value" {
  let (sql, params) = select("emp")
    .window("RANK()", partition_by=["dept"], order_by=[("salary", Desc)])
    .eq("active", Bool(true))
    .build()
  assert_eq(
    sql, "SELECT RANK() OVER (PARTITION BY dept ORDER BY salary DESC) FROM emp WHERE active = ?",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Bool(true), true)
}

///|
test "insert RETURNING: single and multiple columns (sqlite/pg default)" {
  let (sql, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .build()
  assert_eq(sql, "INSERT INTO users (name) VALUES (?) RETURNING id")
  let (sql2, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .returning("created_at")
    .build()
  assert_eq(
    sql2, "INSERT INTO users (name) VALUES (?) RETURNING id, created_at",
  )
  let (sql3, _) = insert("users")
    .set("name", Text("ann"))
    .returning_all()
    .build()
  assert_eq(sql3, "INSERT INTO users (name) VALUES (?) RETURNING *")
}

///|
test "insert RETURNING: MySQL omits the clause" {
  let (sql, _) = insert("users")
    .set("name", Text("ann"))
    .returning("id")
    .build_for(Mysql)
  assert_eq(sql, "INSERT INTO users (name) VALUES (?)")
}

///|
test "upsert DO UPDATE excluded: sqlite/pg form, params in text order" {
  let (sql, params) = insert("kv")
    .set("k", Text("hits"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update_excluded("v")
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("hits"), true)
  assert_eq(params[1] == Int(1), true)
}

///|
test "upsert DO UPDATE bound value binds after the inserted values" {
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update("v", Int(99))
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Text("k1"), true)
  assert_eq(params[1] == Int(1), true)
  assert_eq(params[2] == Int(99), true)
}

///|
test "upsert MySQL form: ON DUPLICATE KEY UPDATE, VALUES() and bound" {
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_update_excluded("v")
    .do_update("seen", Int64(42L))
    .build_for(Mysql)
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v), seen = ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[2] == Int64(42L), true)
}

///|
test "upsert DO NOTHING: sqlite/pg vs MySQL no-op self-assignment" {
  let (sql, _) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_nothing()
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO NOTHING",
  )
  let (my, _) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Int(1))
    .on_conflict(["k"])
    .do_nothing()
    .build_for(Mysql)
  assert_eq(
    my, "INSERT INTO kv (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE k = k",
  )
}

///|
test "upsert RETURNING together: conflict clause then RETURNING, correct params" {
  let (sql, params) = insert("counter")
    .set("name", Text("visits"))
    .set("n", Int(1))
    .on_conflict(["name"])
    .do_update("n", Int(100))
    .returning("n")
    .build()
  assert_eq(
    sql, "INSERT INTO counter (name, n) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET n = ? RETURNING n",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[2] == Int(100), true)
}

///|
test "upsert injection-safe: a hostile value stays bound, never spliced" {
  let evil = "'; DROP TABLE kv; --"
  let (sql, params) = insert("kv")
    .set("k", Text("k1"))
    .set("v", Text(evil))
    .on_conflict(["k"])
    .do_update("v", Text(evil))
    .build()
  assert_eq(
    sql, "INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = ?",
  )
  assert_eq(params[1] == Text(evil), true)
  assert_eq(params[2] == Text(evil), true)
}

///|
test "SELECT DISTINCT dedups the projection" {
  let (sql, _) = select("orders").distinct().column("city").build()
  assert_eq(sql, "SELECT DISTINCT city FROM orders")
}

///|
test "set operations render per the SQL standard" {
  assert_eq(
    select("a").column("x").union(select("b").column("x")).build().0,
    "SELECT x FROM a UNION SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").union_all(select("b").column("x")).build().0,
    "SELECT x FROM a UNION ALL SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").intersect(select("b").column("x")).build().0,
    "SELECT x FROM a INTERSECT SELECT x FROM b",
  )
  assert_eq(
    select("a").column("x").except_(select("b").column("x")).build().0,
    "SELECT x FROM a EXCEPT SELECT x FROM b",
  )
}

///|
test "a trailing ORDER BY / LIMIT binds to the whole compound" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .order_by("x", Asc)
    .limit(10)
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT x FROM b ORDER BY x ASC LIMIT 10",
  )
}

///|
test "parameters thread through both set-operation operands in order" {
  let (sql, params) = select("a")
    .column("x")
    .where_("x", ">", Int(1))
    .union(select("b").column("x").where_("x", "<", Int(9)))
    .build()
  assert_eq(
    sql, "SELECT x FROM a WHERE x > ? UNION SELECT x FROM b WHERE x < ?",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(9), true)
}

///|
test "review fixes: offset-only limit, IS NULL fold, bulk insert, EXISTS" {
  // B2: a bare OFFSET synthesises an effectively-unbounded LIMIT (SQLite/MySQL
  // reject `OFFSET` without `LIMIT`).
  let (o, _) = select("t").offset(10).build()
  assert_eq(o, "SELECT * FROM t LIMIT 9223372036854775807 OFFSET 10")
  // B6: `= NULL` / `!= NULL` fold to IS NULL / IS NOT NULL and bind nothing.
  let (n1, p1) = select("t").eq("a", Null).build()
  assert_eq(n1, "SELECT * FROM t WHERE a IS NULL")
  assert_eq(p1.length(), 0)
  let (n2, _) = select("t").where_("a", "!=", Null).build()
  assert_eq(n2, "SELECT * FROM t WHERE a IS NOT NULL")
  // Bulk insert: one VALUES tuple per row, every value bound in order.
  let (bi, bp) = insert("t")
    .set("a", Int(1))
    .set("b", Int(2))
    .values([Int(3), Int(4)])
    .values([Int(5), Int(6)])
    .build()
  assert_eq(bi, "INSERT INTO t (a, b) VALUES (?, ?), (?, ?), (?, ?)")
  assert_eq(bp.length(), 6)
  assert_eq(bp[4] == Int(5), true)
  // EXISTS subquery, its bound value spliced in at position.
  let sub = select("o").column("1").where_("o.uid", "=", Int(7))
  let (e, ep) = select("u").where_exists(sub).build()
  assert_eq(e, "SELECT * FROM u WHERE EXISTS (SELECT 1 FROM o WHERE o.uid = ?)")
  assert_eq(ep[0] == Int(7), true)
}
