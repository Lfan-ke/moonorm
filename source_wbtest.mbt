///|
test "FROM a derived table: its values bind before the WHERE's" {
  let sub = select("orders").column("uid").where_("total", ">", Int(100))
  let (sql, params) = select(Alias(Sub(sub), "o"))
    .column("o.uid")
    .where_("o.uid", "<", Int(50))
    .build()
  assert_eq(
    sql, "SELECT o.uid FROM (SELECT uid FROM orders WHERE total > ?) AS o WHERE o.uid < ?",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(100), true)
  assert_eq(params[1] == Int(50), true)
}

///|
test "JOIN a derived table: FROM, JOIN then WHERE values, in text order" {
  let a = select("a").column("id").where_("x", "=", Int(1))
  let b = select("b").column("id").where_("y", "=", Int(2))
  let (sql, params) = select(Alias(Sub(a), "ta"))
    .column("ta.id")
    .join(Alias(Sub(b), "tb"), "tb.id = ta.id")
    .where_("ta.id", ">", Int(3))
    .build()
  assert_eq(
    sql, "SELECT ta.id FROM (SELECT id FROM a WHERE x = ?) AS ta JOIN (SELECT id FROM b WHERE y = ?) AS tb ON tb.id = ta.id WHERE ta.id > ?",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "aliased tables in FROM and JOIN" {
  let (sql, _) = select(Alias(Tbl("users"), "u"))
    .column("u.id")
    .left_join(Alias(Tbl("teams"), "t"), "t.id = u.team_id")
    .build()
  assert_eq(
    sql, "SELECT u.id FROM users AS u LEFT JOIN teams AS t ON t.id = u.team_id",
  )
}

///|
test "a bare table name still reads as a source" {
  let (sql, _) = select("users")
    .join("teams", "teams.id = users.team_id")
    .build()
  assert_eq(sql, "SELECT * FROM users JOIN teams ON teams.id = users.team_id")
}

///|
test "the other join kinds: right, full, cross, using" {
  assert_eq(
    select("a").right_join("b", "b.k = a.k").build().0,
    "SELECT * FROM a RIGHT JOIN b ON b.k = a.k",
  )
  assert_eq(
    select("a").full_join("b", "b.k = a.k").build().0,
    "SELECT * FROM a FULL JOIN b ON b.k = a.k",
  )
  assert_eq(
    select("a").cross_join("b").build().0,
    "SELECT * FROM a CROSS JOIN b",
  )
  assert_eq(
    select("a").join_using("b", ["k", "j"]).build().0,
    "SELECT * FROM a JOIN b USING (k, j)",
  )
}

///|
test "LATERAL: a per-row derived table, values bound" {
  let sub = select("orders")
    .column("id")
    .where_("orders.uid", "=", Int(5))
    .limit(3)
  let (sql, params) = select("users")
    .cross_join(Alias(Lateral(Sub(sub)), "o"))
    .build()
  assert_eq(
    sql, "SELECT * FROM users CROSS JOIN LATERAL (SELECT id FROM orders WHERE orders.uid = ? LIMIT 3) AS o",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(5), true)
}

///|
test "ORDER BY places NULLs when asked" {
  let (sql, _) = select("t")
    .order_by("a", Asc, nulls=Last)
    .order_by("b", Desc, nulls=First)
    .order_by("c", Asc)
    .build()
  assert_eq(
    sql, "SELECT * FROM t ORDER BY a ASC NULLS LAST, b DESC NULLS FIRST, c ASC",
  )
}

///|
test "DISTINCT ON keeps the first row of each group" {
  let (sql, _) = select("t")
    .distinct_on(["a"])
    .column("a")
    .column("b")
    .order_by("a", Asc)
    .order_by("b", Desc)
    .build()
  assert_eq(sql, "SELECT DISTINCT ON (a) a, b FROM t ORDER BY a ASC, b DESC")
}

///|
test "expression helpers: func, cast, case_, label" {
  let (sql, _) = select("t")
    .label(func("coalesce", ["a", "b"]), "ab")
    .raw(cast("price", "NUMERIC(10,2)"))
    .raw(case_([("x > 0", "'pos'")], else_="'neg'"))
    .build()
  assert_eq(
    sql, "SELECT coalesce(a, b) AS ab, CAST(price AS NUMERIC(10,2)), CASE WHEN x > 0 THEN 'pos' ELSE 'neg' END FROM t",
  )
  assert_eq(
    case_([("a", "1"), ("b", "2")]),
    "CASE WHEN a THEN 1 WHEN b THEN 2 END",
  )
  assert_eq(case_([]), "NULL")
  assert_eq(case_([], else_="0"), "0")
}
