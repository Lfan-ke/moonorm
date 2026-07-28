// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Integration tests against a REAL PostgreSQL. Gated on the `MOON_PG_TEST`
// environment variable so a local checkout without a database is skipped
// cleanly; CI sets it (see .github/workflows/ci.yml, which stands up a
// `postgres:16` service). Connection parameters come from the standard `PG*`
// environment variables with localhost defaults.

///|
fn env_or(key : String, default : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => if v == "" { default } else { v }
    None => default
  }
}

///|
fn env_port() -> Int {
  match parse_int(env_or("PGPORT", "5432")) {
    Some(p) => p
    None => 5432
  }
}

///|
async test "integration: connect, DDL, parameterised INSERT, SELECT round trip" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
  conn.execute("DROP TABLE IF EXISTS moon_pg_t", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_t (id int, name text)", []) |> ignore

  // parameterised INSERT: '?' is translated to '$1','$2' and bound out-of-band
  let r1 = conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("alice"),
  ])
  assert_eq(r1.rows_affected, 1L)
  conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(2),
    @moondb.Text("o'brien"),
  ])
  |> ignore

  // a NULL parameter must round-trip as SQL NULL, not the text "NULL"
  conn.execute("INSERT INTO moon_pg_t VALUES (?, ?)", [
    @moondb.Int(3),
    @moondb.Null,
  ])
  |> ignore
  let rows = conn.query("SELECT id, name FROM moon_pg_t ORDER BY id", [])
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].int_by("id"), 1)
  assert_eq(rows[0].text_by("name"), "alice")
  assert_eq(rows[1].int(0), 2)
  assert_eq(rows[1].text(1), "o'brien") // injection-safe quote handling
  assert_eq(rows[2].is_null_by("name"), true)
  conn.close()
}

///|
async test "integration: transactions commit and roll back" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
  conn.execute("DROP TABLE IF EXISTS moon_pg_tx", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_tx (n int)", []) |> ignore
  conn.begin()
  conn.execute("INSERT INTO moon_pg_tx VALUES (?)", [@moondb.Int(10)]) |> ignore
  conn.rollback()
  let after_rollback = conn.query("SELECT count(*) FROM moon_pg_tx", [])
  assert_eq(after_rollback[0].int64(0), 0L)
  conn.begin()
  conn.execute("INSERT INTO moon_pg_tx VALUES (?)", [@moondb.Int(20)]) |> ignore
  conn.commit()
  let after_commit = conn.query("SELECT n FROM moon_pg_tx", [])
  assert_eq(after_commit.length(), 1)
  assert_eq(after_commit[0].int(0), 20)
  conn.close()
}

///|
test "PgDriver conforms to @moondb.Driver; sync I/O raises (async wall)" {
  let d = PgDriver::new(host="127.0.0.1", user="postgres", database="test")
  let drv : &@moondb.Driver = d
  let raised = try {
    drv.execute("SELECT 1", []) |> ignore
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
  // close is best-effort and must never raise
  drv.close()
}
