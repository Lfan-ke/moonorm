///|
test "where_pred: OR grouping stays parameterized" {
  let (sql, params) = select("users")
    .column("id")
    .where_pred(
      Or([
        Cmp(col="name", op="=", val=Text("a")),
        Cmp(col="name", op="=", val=Text("b")),
      ]),
    )
    .build()
  assert_eq(sql, "SELECT id FROM users WHERE (name = ? OR name = ?)")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("a"), true)
  assert_eq(params[1] == Text("b"), true)
}

///|
test "where_pred: nested AND/OR/NOT and mixing with eq" {
  let (sql, params) = select("t")
    .eq("active", Bool(true))
    .where_pred(
      And([
        Or([Cmp(col="a", op=">", val=Int(1)), Cmp(col="b", op="<", val=Int(9))]),
        Not(Cmp(col="c", op="=", val=Int(0))),
      ]),
    )
    .build()
  assert_eq(
    sql, "SELECT * FROM t WHERE active = ? AND ((a > ? OR b < ?) AND NOT (c = ?))",
  )
  assert_eq(params.length(), 4)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[3] == Int(0), true)
}

///|
test "where_pred: IN list inside a predicate tree" {
  let (sql, _) = select("t")
    .where_pred(InList(col="id", vals=[Int(1), Int(2), Int(3)], negated=false))
    .build()
  assert_eq(sql, "SELECT * FROM t WHERE id IN (?, ?, ?)")
}
