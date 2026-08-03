// Row-locking clause on a SELECT (SQLAlchemy `with_for_update`).

///|
test "for_update: FOR UPDATE/FOR SHARE with OF, NOWAIT and SKIP LOCKED, after LIMIT" {
  // FOR UPDATE is emitted after LIMIT/OFFSET.
  let (sql1, _) = select("t").limit(5).for_update().build()
  assert_eq(sql1.contains("LIMIT 5 FOR UPDATE"), true)
  // read=true selects FOR SHARE instead.
  let (sql2, _) = select("t").for_update(read=true).build()
  assert_eq(sql2.contains("FOR SHARE"), true)
  assert_eq(sql2.contains("FOR UPDATE"), false)
  // OF restricts the lock; NOWAIT fails fast on a locked row.
  let (sql3, _) = select("t").for_update(of=["t"], nowait=true).build()
  assert_eq(sql3.contains("FOR UPDATE OF t NOWAIT"), true)
  // SKIP LOCKED skips locked rows.
  let (sql4, _) = select("t").for_update(skip_locked=true).build()
  assert_eq(sql4.contains("FOR UPDATE SKIP LOCKED"), true)
  // No lock requested: no locking clause.
  let (sql5, _) = select("t").build()
  assert_eq(sql5.contains("FOR UPDATE"), false)
  assert_eq(sql5.contains("FOR SHARE"), false)
}
