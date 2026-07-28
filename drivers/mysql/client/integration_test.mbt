// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Read an environment variable, falling back to `default`.
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(v) => v
    None => default
  }
}

///|
/// End-to-end roundtrip against a real MySQL server. It is gated on `MYSQL_TEST`
/// so the local `moon test` (which usually has no database) skips it, while CI —
/// which starts a MySQL 8 service and exports `MYSQL_TEST=1` — runs it for real.
/// Connection details come from `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` /
/// `MYSQL_PASSWORD` / `MYSQL_DB`, each with a sensible default.
///
/// It drives the whole text protocol through the synchronous `@moondb.Driver`
/// surface: connect + mysql_native_password auth, a DDL `execute`, parameter-
/// bound `execute`s (integers, UTF-8 text, an embedded quote — the escaping
/// path), and a `query` whose rows are asserted cell by cell. Breaking the
/// row-packet decoder turns the row assertions red (mutation check).
test "integration: real MySQL CREATE/INSERT/SELECT roundtrip" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let host = env_or("MYSQL_HOST", "127.0.0.1")
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  let db = MysqlDriver::new(
    host~,
    port~,
    user=env_or("MYSQL_USER", "root"),
    password=env_or("MYSQL_PASSWORD", "root"),
    database=env_or("MYSQL_DB", "test"),
  )
  let _ = db.execute("DROP TABLE IF EXISTS t_moon_mysql", [])
  let _ = db.execute(
    "CREATE TABLE t_moon_mysql (id INT PRIMARY KEY, name TEXT)",
    [],
  )
  let r1 = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("a"),
  ])
  assert_eq(r1.rows_affected, 1L)
  // UTF-8 text and an embedded single quote exercise the escaping path.
  let _ = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(2),
    @moondb.Text("béta"),
  ])
  let _ = db.execute("INSERT INTO t_moon_mysql VALUES (?, ?)", [
    @moondb.Int(3),
    @moondb.Text("a'b"),
  ])
  let rows = db.query("SELECT id, name FROM t_moon_mysql ORDER BY id", [])
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "a")
  assert_eq(rows[1].int_by("id"), 2)
  assert_eq(rows[1].text_by("name"), "béta")
  assert_eq(rows[2].text_by("name"), "a'b")
  // A query against a missing table surfaces the server's ERR as a DbError.
  let missing = try {
    let _ = db.query("SELECT * FROM no_such_table_here", [])
    "no-error"
  } catch {
    _ => "errored"
  }
  assert_eq(missing, "errored")
}
