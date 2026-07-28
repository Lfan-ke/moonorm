// Real end-to-end integration tests: these open an actual SQLite database, run the
// query builder's statements through the native driver, and read rows back. If the
// driver does not truly execute, these assertions fail (mutation-verified: breaking
// the C bind/step/column path turns them red).

///|
fn open_or_fail(path : String) -> SqliteConn {
  match SqliteConn::open(path) {
    Ok(c) => c
    Err(e) => {
      println("open failed: " + e.to_string())
      abort("cannot open sqlite db")
    }
  }
}

///|
test "sqlite: builder INSERT then SELECT round-trips real rows" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  guard sess.execute(
      "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
      [],
    )
    is Ok(_)
  // INSERT through the builder — values travel as bound params.
  let ins = @moonorm.insert("users")
    .set("name", @moonorm.Text("alice"))
    .set("age", @moonorm.Int(30))
  let er = match sess.add(ins) {
    Ok(x) => x
    Err(e) => {
      println(e.to_string())
      abort("insert failed")
    }
  }
  assert_eq(er.rows_affected, 1)
  assert_eq(er.last_insert_id, 1L)
  guard sess.add(
      @moonorm.insert("users")
      .set("name", @moonorm.Text("bob"))
      .set("age", @moonorm.Int(17)),
    )
    is Ok(_)
  // SELECT through the builder — WHERE / ORDER BY reach the real engine.
  let sel = @moonorm.select("users")
    .column("name")
    .column("age")
    .where_("age", ">", @moonorm.Int(18))
    .order_by("name", @moonorm.Asc)
  let rows = match sess.fetch(sel) {
    Ok(rs) => rs
    Err(e) => {
      println(e.to_string())
      abort("select failed")
    }
  }
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), Some("alice"))
  assert_eq(rows[0].int(1), Some(30))
  assert_eq(rows[0].by_name("name"), Some(@moonorm.Text("alice")))
  sess.close()
}

///|
test "sqlite: injection attempt is bound, not executed" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  guard sess.execute("CREATE TABLE t (name TEXT)", []) is Ok(_)
  guard sess.add(@moonorm.insert("t").set("name", @moonorm.Text("safe")))
    is Ok(_)
  // Classic injection string as a bound value: the table must survive and the
  // row is stored verbatim, proving the value never became SQL.
  let evil = "'; DROP TABLE t; --"
  guard sess.add(@moonorm.insert("t").set("name", @moonorm.Text(evil))) is Ok(_)
  let rows = match
    sess.fetch(
      @moonorm.select("t").column("name").order_by("name", @moonorm.Asc),
    ) {
    Ok(rs) => rs
    Err(_) => abort("select failed")
  }
  // Table still exists (DROP was never executed) and holds both literal strings.
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text(0), Some(evil))
  assert_eq(rows[1].text(0), Some("safe"))
  sess.close()
}

///|
test "sqlite: UPDATE and DELETE affect the expected row counts" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  guard sess.execute("CREATE TABLE p (id INTEGER, qty INTEGER)", []) is Ok(_)
  for i = 1; i <= 3; i = i + 1 {
    guard sess.add(
        @moonorm.insert("p")
        .set("id", @moonorm.Int(i))
        .set("qty", @moonorm.Int(i)),
      )
      is Ok(_)
  }
  let up = match
    sess.modify(
      @moonorm.update("p")
      .set("qty", @moonorm.Int(99))
      .where_("id", ">", @moonorm.Int(1)),
    ) {
    Ok(x) => x
    Err(_) => abort("update failed")
  }
  assert_eq(up.rows_affected, 2)
  let del = match
    sess.remove(@moonorm.delete("p").where_("qty", "=", @moonorm.Int(99))) {
    Ok(x) => x
    Err(_) => abort("delete failed")
  }
  assert_eq(del.rows_affected, 2)
  let rows = match sess.fetch(@moonorm.select("p")) {
    Ok(rs) => rs
    Err(_) => abort("select failed")
  }
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), Some(1))
  sess.close()
}

///|
test "sqlite: exec_script runs a multi-statement schema and Double round-trips" {
  let conn = open_or_fail(":memory:")
  guard conn.exec_script(
      "CREATE TABLE m (k TEXT, v REAL); INSERT INTO m VALUES ('pi', 3.5);",
    )
    is Ok(_)
  let sess = @moonorm.Session::new(conn)
  let rows = match sess.fetch(@moonorm.select("m").column("k").column("v")) {
    Ok(rs) => rs
    Err(_) => abort("select failed")
  }
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), Some("pi"))
  assert_eq(rows[0].double(1), Some(3.5))
  sess.close()
}
