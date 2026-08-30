///|
test "update: a column can be set to an expression over itself" {
  let (sql, params) = update("counters")
    .set_expr("n", "n + ?", vals=[Int(1)])
    .where_("id", "=", Int(7))
    .build()
  assert_eq(sql, "UPDATE counters SET n = n + ? WHERE id = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(7), true)
}

///|
test "update: bound and expression assignments mix, in call order" {
  let (sql, params) = update("t")
    .set("a", Text("qwq"))
    .set_expr("n", "n + 1")
    .set("b", Int(233))
    .build()
  assert_eq(sql, "UPDATE t SET a = ?, n = n + 1, b = ?")
  assert_eq(params.length(), 2)
  assert_eq(params[0] == Text("qwq"), true)
  assert_eq(params[1] == Int(233), true)
}

///|
test "update: a predicate tree narrows it like a query" {
  let (sql, params) = update("t")
    .set("a", Int(1))
    .where_pred(
      Or([Cmp(col="b", op="=", val=Int(2)), Cmp(col="c", op="=", val=Int(3))]),
    )
    .build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE (b = ? OR c = ?)")
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Int(1), true)
  assert_eq(params[1] == Int(2), true)
  assert_eq(params[2] == Int(3), true)
}

///|
test "update: IN (subquery), with SET / WHERE / subquery values in text order" {
  let (sql, params) = update("t")
    .set("flag", Bool(true))
    .where_("k", "=", Int(9))
    .where_in("id", select("s").column("id").where_("x", ">", Int(5)))
    .build()
  assert_eq(
    sql, "UPDATE t SET flag = ? WHERE k = ? AND id IN (SELECT id FROM s WHERE x > ?)",
  )
  assert_eq(params.length(), 3)
  assert_eq(params[0] == Bool(true), true)
  assert_eq(params[1] == Int(9), true)
  assert_eq(params[2] == Int(5), true)
}

///|
test "update: NOT IN (subquery)" {
  let (sql, _) = update("t")
    .set("a", Int(1))
    .where_not_in("id", select("s").column("id"))
    .build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE id NOT IN (SELECT id FROM s)")
}

///|
test "update RETURNING: sqlite/pg emit it, MySQL drops it" {
  let stmt = update("t").set("a", Int(1)).where_("id", "=", Int(2))
  let (sql, params) = stmt.returning("id").returning("a").build()
  assert_eq(sql, "UPDATE t SET a = ? WHERE id = ? RETURNING id, a")
  assert_eq(params.length(), 2)
  let (my, _) = stmt.returning("id").build_for(Mysql)
  assert_eq(my, "UPDATE t SET a = ? WHERE id = ?")
  let (star, _) = stmt.returning_all().build()
  assert_eq(star, "UPDATE t SET a = ? WHERE id = ? RETURNING *")
}

///|
test "delete: predicate tree, subquery, RETURNING" {
  let (p, pp) = delete("t")
    .where_pred(Not(Cmp(col="a", op="=", val=Int(1))))
    .returning_all()
    .build()
  assert_eq(p, "DELETE FROM t WHERE NOT (a = ?) RETURNING *")
  assert_eq(pp.length(), 1)
  assert_eq(pp[0] == Int(1), true)
  let (s, sp) = delete("t")
    .where_("k", "=", Text("hhh"))
    .where_in("id", select("s").column("id").where_("y", "<", Int(4)))
    .build()
  assert_eq(
    s, "DELETE FROM t WHERE k = ? AND id IN (SELECT id FROM s WHERE y < ?)",
  )
  assert_eq(sp.length(), 2)
  assert_eq(sp[0] == Text("hhh"), true)
  assert_eq(sp[1] == Int(4), true)
  let (n, _) = delete("t").where_not_in("id", select("s").column("id")).build()
  assert_eq(n, "DELETE FROM t WHERE id NOT IN (SELECT id FROM s)")
  let (my, _) = delete("t")
    .where_("id", "=", Int(1))
    .returning("id")
    .build_for(Mysql)
  assert_eq(my, "DELETE FROM t WHERE id = ?")
}

///|
test "insert: a bulk row without a leading set() emits no empty tuple" {
  let (sql, params) = insert("t").values([Int(233)]).build()
  assert_eq(sql, "INSERT INTO t VALUES (?)")
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(233), true)
  let (two, tp) = insert("t")
    .values([Int(1), Int(2)])
    .values([Int(3), Int(4)])
    .build()
  assert_eq(two, "INSERT INTO t VALUES (?, ?), (?, ?)")
  assert_eq(tp.length(), 4)
}

///|
test "insert: nothing to insert is DEFAULT VALUES, or MySQL's () VALUES ()" {
  let (sql, params) = insert("t").build()
  assert_eq(sql, "INSERT INTO t DEFAULT VALUES")
  assert_eq(params.length(), 0)
  let (my, _) = insert("t").build_for(Mysql)
  assert_eq(my, "INSERT INTO t () VALUES ()")
}

///|
test "predicate tree: = NULL folds to IS NULL inside the tree too" {
  let (sql, params) = select("t")
    .where_pred(
      Or([Cmp(col="a", op="=", val=Null), Cmp(col="b", op="=", val=Int(1))]),
    )
    .build()
  assert_eq(sql, "SELECT * FROM t WHERE (a IS NULL OR b = ?)")
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(1), true)
  let (ne, np) = select("t")
    .where_pred(And([Cmp(col="a", op="!=", val=Null)]))
    .build()
  assert_eq(ne, "SELECT * FROM t WHERE a IS NOT NULL")
  assert_eq(np.length(), 0)
}

///|
test "having: = NULL folds the same way" {
  let (sql, params) = select("t")
    .group_by("g")
    .having("MAX(x)", "=", Null)
    .having("COUNT(*)", ">", Int(3))
    .build()
  assert_eq(
    sql, "SELECT * FROM t GROUP BY g HAVING MAX(x) IS NULL AND COUNT(*) > ?",
  )
  assert_eq(params.length(), 1)
  assert_eq(params[0] == Int(3), true)
}
