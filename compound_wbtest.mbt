///|
test "a tighter-binding operator does not silently regroup what is left of it" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .intersect(select("c").column("x"))
    .build()
  assert_eq(
    sql, "SELECT * FROM (SELECT x FROM a UNION SELECT x FROM b) AS _c INTERSECT SELECT x FROM c",
  )
}

///|
test "one repeated operator needs no grouping" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(sql, "SELECT x FROM a UNION SELECT x FROM b UNION SELECT x FROM c")
  let (e, _) = select("a")
    .column("x")
    .except_(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(e, "SELECT x FROM a EXCEPT SELECT x FROM b UNION SELECT x FROM c")
}

///|
test "a looser operator after a tighter one already groups correctly" {
  let (sql, _) = select("a")
    .column("x")
    .intersect(select("b").column("x"))
    .union(select("c").column("x"))
    .build()
  assert_eq(
    sql, "SELECT x FROM a INTERSECT SELECT x FROM b UNION SELECT x FROM c",
  )
}

///|
test "a compound operand becomes a derived table so it keeps its own shape" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("b").column("x").intersect(select("c").column("x")))
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b INTERSECT SELECT x FROM c) AS _c",
  )
}

///|
test "an operand's own ORDER BY / LIMIT stays its own" {
  let (sql, params) = select("a")
    .column("x")
    .where_("x", ">", Int(1))
    .union(select("b").column("x").where_("x", "<", Int(9)).limit(2))
    .build()
  assert_eq(
    sql, "SELECT x FROM a WHERE x > ? UNION SELECT * FROM (SELECT x FROM b WHERE x < ? LIMIT 2) AS _c",
  )
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(9), true)
  let (o, _) = select("a")
    .column("x")
    .union(select("b").column("x").order_by("x", Desc))
    .build()
  assert_eq(
    o, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b ORDER BY x DESC) AS _c",
  )
  let (off, _) = select("a")
    .column("x")
    .union(select("b").column("x").offset(5))
    .build()
  assert_eq(
    off, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b LIMIT 9223372036854775807 OFFSET 5) AS _c",
  )
  let (lock, _) = select("a")
    .column("x")
    .union(select("b").column("x").for_update())
    .build()
  assert_eq(
    lock, "SELECT x FROM a UNION SELECT * FROM (SELECT x FROM b FOR UPDATE) AS _c",
  )
}

///|
test "an operand carrying its own WITH is grouped too" {
  let (sql, _) = select("a")
    .column("x")
    .union(select("cte").column("x").with_cte("cte", select("b").column("x")))
    .build()
  assert_eq(
    sql, "SELECT x FROM a UNION SELECT * FROM (WITH cte AS (SELECT x FROM b) SELECT x FROM cte) AS _c",
  )
}
