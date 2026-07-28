// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Versioned schema migrations — the Alembic/`alembic upgrade`, Diesel-migrations
// counterpart. A `Migration` bundles an integer version with the forward (`up`) and
// reverse (`down`) statement lists; a `Migrator` tracks which versions are applied
// in a `schema_migrations` table and drives the schema forward or back. Everything
// runs through the `@moondb.Driver` seam, so the same migrations apply against the
// MockDriver, real SQLite, or any other backend.

///|
/// One schema change: a monotonically increasing `version`, a human `name`, and the
/// ordered SQL statements that apply it (`up`) and undo it (`down`). Each statement
/// runs through `Session::execute`, so a backend that prepares one statement per
/// call (SQLite) still applies a multi-statement migration.
pub(all) struct Migration {
  version : Int
  name : String
  up : Array[String]
  down : Array[String]
}

///|
/// Tracks and applies migrations against a `schema_migrations`-style bookkeeping
/// table (its name is configurable for coexistence with other tools). Build one
/// with `Migrator::new`.
pub struct Migrator {
  table : String
}

///|
/// A migrator recording applied versions in `table` (default `schema_migrations`).
/// The name must be a bare SQL identifier — it is interpolated as an identifier,
/// never bound — so a non-identifier is refused up front.
pub fn Migrator::new(
  table? : String = "schema_migrations",
) -> Migrator raise @moondb.DbError {
  if !is_ident(table) {
    raise @moondb.QueryError("invalid migrations table name: " + table)
  }
  { table, }
}

///|
/// Create the bookkeeping table if it is absent. Idempotent, so it is safe to call
/// before every `up`/`down`.
pub fn Migrator::ensure_table(
  self : Migrator,
  sess : Session,
) -> Unit raise @moondb.DbError {
  sess.execute(
    "CREATE TABLE IF NOT EXISTS " +
    self.table +
    " (version INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    [],
  )
  |> ignore
}

///|
/// Every applied version, ascending.
pub fn Migrator::applied_versions(
  self : Migrator,
  sess : Session,
) -> Array[Int] raise @moondb.DbError {
  self.ensure_table(sess)
  let rows = sess.query(
    "SELECT version FROM " + self.table + " ORDER BY version ASC",
    [],
  )
  let out : Array[Int] = []
  for r in rows {
    out.push(r.int(0))
  }
  out
}

///|
/// The highest applied version, or `0` when nothing has been applied yet.
pub fn Migrator::current_version(
  self : Migrator,
  sess : Session,
) -> Int raise @moondb.DbError {
  let vs = self.applied_versions(sess)
  if vs.length() == 0 {
    0
  } else {
    vs[vs.length() - 1]
  }
}

///|
/// Whether `version` is recorded as applied.
fn Migrator::is_applied(
  self : Migrator,
  sess : Session,
  version : Int,
) -> Bool raise @moondb.DbError {
  let rows = sess.query(
    "SELECT version FROM " + self.table + " WHERE version = ?",
    [Int(version)],
  )
  rows.length() > 0
}

///|
/// Apply every pending migration (those whose version is not yet recorded), in
/// ascending version order, running each one's `up` statements and recording it.
/// Returns how many were applied. Already-applied versions are skipped, so this is
/// safe to run repeatedly (it converges the schema to the latest version).
pub fn Migrator::up(
  self : Migrator,
  sess : Session,
  migrations : Array[Migration],
) -> Int raise @moondb.DbError {
  self.ensure_table(sess)
  let ordered = sort_by_version(migrations, ascending=true)
  let mut applied = 0
  for m in ordered {
    if self.is_applied(sess, m.version) {
      continue
    }
    for stmt in m.up {
      sess.execute(stmt, []) |> ignore
    }
    sess.execute(
      "INSERT INTO " + self.table + " (version, name) VALUES (?, ?)",
      [Int(m.version), Text(m.name)],
    )
    |> ignore
    applied = applied + 1
  }
  applied
}

///|
/// Roll back every applied migration whose version is greater than `target`, in
/// descending version order, running each one's `down` statements and removing its
/// bookkeeping row. Returns how many were rolled back. `down_to(0)` unwinds
/// everything.
pub fn Migrator::down_to(
  self : Migrator,
  sess : Session,
  migrations : Array[Migration],
  target : Int,
) -> Int raise @moondb.DbError {
  self.ensure_table(sess)
  let ordered = sort_by_version(migrations, ascending=false)
  let mut rolled = 0
  for m in ordered {
    if m.version <= target {
      continue
    }
    if !self.is_applied(sess, m.version) {
      continue
    }
    for stmt in m.down {
      sess.execute(stmt, []) |> ignore
    }
    sess.execute("DELETE FROM " + self.table + " WHERE version = ?", [
      Int(m.version),
    ])
    |> ignore
    rolled = rolled + 1
  }
  rolled
}

///|
/// Return a copy of `migrations` sorted by version. Migrations are typically a
/// handful, so an insertion sort keeps the code obvious and stable (equal versions
/// keep their input order, though versions are expected unique).
fn sort_by_version(
  migrations : Array[Migration],
  ascending~ : Bool,
) -> Array[Migration] {
  let out : Array[Migration] = []
  for m in migrations {
    out.push(m)
  }
  for i in 1..<out.length() {
    let key = out[i]
    let mut j = i - 1
    while j >= 0 {
      let greater = out[j].version > key.version
      let move_it = if ascending { greater } else { !greater }
      if move_it {
        out[j + 1] = out[j]
        j = j - 1
      } else {
        break
      }
    }
    out[j + 1] = key
  }
  out
}
