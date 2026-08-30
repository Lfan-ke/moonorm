///|
test "a Select is a safe base to branch from" {
  let base = select("t").column("id")
  let a = base.eq("k", Int(1))
  let b = base.eq("k", Int(2))
  assert_eq(base.build().0, "SELECT id FROM t")
  let (asql, ap) = a.build()
  assert_eq(asql, "SELECT id FROM t WHERE k = ?")
  assert_eq(ap.length(), 1)
  assert_eq(ap[0] == Int(1), true)
  let (bsql, bp) = b.build()
  assert_eq(bsql, "SELECT id FROM t WHERE k = ?")
  assert_eq(bp[0] == Int(2), true)
}

///|
test "branching leaves the base untouched, clause by clause" {
  let base = select("t").column("id").order_by("id", Asc)
  let tail = " ORDER BY id ASC"
  assert_eq(base.column("name").build().0, "SELECT id, name FROM t" + tail)
  assert_eq(
    base.join("u", "u.id = t.id").build().0,
    "SELECT id FROM t JOIN u ON u.id = t.id" + tail,
  )
  assert_eq(
    base.with_cte("c", select("z")).build().0,
    "WITH c AS (SELECT * FROM z) SELECT id FROM t" + tail,
  )
  assert_eq(
    base.group_by("k").having("COUNT(*)", ">", Int(1)).build().0,
    "SELECT id FROM t GROUP BY k HAVING COUNT(*) > ?" + tail,
  )
  assert_eq(
    base.order_by("k", Desc).build().0,
    "SELECT id FROM t ORDER BY id ASC, k DESC",
  )
  assert_eq(
    base.distinct_on(["id"]).build().0,
    "SELECT DISTINCT ON (id) id FROM t" + tail,
  )
  assert_eq(base.limit(5).build().0, "SELECT id FROM t" + tail + " LIMIT 5")
  assert_eq(
    base.for_update().build().0,
    "SELECT id FROM t" + tail + " FOR UPDATE",
  )
  assert_eq(
    base.union(select("u").column("id")).build().0,
    "SELECT id FROM t UNION SELECT id FROM u" + tail,
  )
  assert_eq(
    base.eq("k", Int(1)).build().0,
    "SELECT id FROM t WHERE k = ?" + tail,
  )
  assert_eq(
    base.where_in_values("k", [Int(1)]).build().0,
    "SELECT id FROM t WHERE k IN (?)" + tail,
  )
  assert_eq(
    base.where_in("k", select("z").column("id")).build().0,
    "SELECT id FROM t WHERE k IN (SELECT id FROM z)" + tail,
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(1))).build().0,
    "SELECT id FROM t WHERE k = ?" + tail,
  )
  assert_eq(base.build().0, "SELECT id FROM t" + tail)
}

///|
test "with_recursive leaves the anchor a plain query" {
  let anchor = select("n").column("x").where_("x", "=", Int(0))
  let step = select("n").column("x + 1")
  let q = select("n").with_recursive("n", anchor, step)
  assert_eq(anchor.build().0, "SELECT x FROM n WHERE x = ?")
  assert_eq(
    q.build().0,
    "WITH RECURSIVE n AS (SELECT x FROM n WHERE x = ? UNION SELECT x + 1 FROM n) SELECT * FROM n",
  )
}

///|
test "a set operation leaves both operands alone" {
  let a = select("a").column("x")
  let b = select("b").column("x")
  let both = a.union(b)
  assert_eq(a.build().0, "SELECT x FROM a")
  assert_eq(b.build().0, "SELECT x FROM b")
  assert_eq(both.build().0, "SELECT x FROM a UNION SELECT x FROM b")
}

///|
test "an Insert is a safe base to branch from" {
  let base = insert("t").set("a", Int(1))
  assert_eq(
    base.set("b", Int(2)).build().0,
    "INSERT INTO t (a, b) VALUES (?, ?)",
  )
  assert_eq(
    base.values([Int(9)]).build().0,
    "INSERT INTO t (a) VALUES (?), (?)",
  )
  assert_eq(
    base.returning("id").build().0,
    "INSERT INTO t (a) VALUES (?) RETURNING id",
  )
  assert_eq(base.build().0, "INSERT INTO t (a) VALUES (?)")
}

///|
test "an Insert's upsert clause branches too" {
  let up = insert("kv").set("k", Text("emm")).on_conflict(["k"])
  let overwrite = up.do_update_excluded("v")
  let wider = up.on_conflict(["j"])
  let nothing = up.do_nothing()
  assert_eq(
    overwrite.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k) DO UPDATE SET v = excluded.v",
  )
  assert_eq(
    wider.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k, j) DO UPDATE SET ",
  )
  assert_eq(
    nothing.build().0,
    "INSERT INTO kv (k) VALUES (?) ON CONFLICT (k) DO NOTHING",
  )
}

///|
test "an Update is a safe base to branch from" {
  let base = update("t").set("a", Int(1))
  let (u1, p1) = base.where_("id", "=", Int(1)).build()
  let (u2, p2) = base.where_("id", "=", Int(2)).build()
  assert_eq(u1, "UPDATE t SET a = ? WHERE id = ?")
  assert_eq(u2, "UPDATE t SET a = ? WHERE id = ?")
  assert_eq(p1[1] == Int(1), true)
  assert_eq(p2[1] == Int(2), true)
  assert_eq(base.set("b", Int(2)).build().0, "UPDATE t SET a = ?, b = ?")
  assert_eq(
    base.set_expr("n", "n + 1").build().0,
    "UPDATE t SET a = ?, n = n + 1",
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(3))).build().0,
    "UPDATE t SET a = ? WHERE k = ?",
  )
  assert_eq(
    base.where_in("id", select("s").column("id")).build().0,
    "UPDATE t SET a = ? WHERE id IN (SELECT id FROM s)",
  )
  assert_eq(base.returning("id").build().0, "UPDATE t SET a = ? RETURNING id")
  assert_eq(base.build().0, "UPDATE t SET a = ?")
}

///|
test "a Delete is a safe base to branch from" {
  let base = delete("t")
  assert_eq(
    base.where_("id", "=", Int(1)).build().0,
    "DELETE FROM t WHERE id = ?",
  )
  assert_eq(
    base.where_pred(Cmp(col="k", op="=", val=Int(3))).build().0,
    "DELETE FROM t WHERE k = ?",
  )
  assert_eq(
    base.where_in("id", select("s").column("id")).build().0,
    "DELETE FROM t WHERE id IN (SELECT id FROM s)",
  )
  assert_eq(base.returning("id").build().0, "DELETE FROM t RETURNING id")
  assert_eq(base.build().0, "DELETE FROM t")
}
