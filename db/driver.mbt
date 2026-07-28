// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The contract every database backend implements and every query layer is written
/// against — the seam moondb exists to define. It is the MoonBit transliteration of
/// Go's `database/sql/driver.Conn`/`Execer`/`Queryer` and Python's DB-API 2.0
/// `Connection`/`Cursor`, reduced to the smallest set of operations a relational
/// backend must offer.
///
/// ## The binding contract
///
/// `execute` and `query` both take `(sql, params)`. `sql` carries **positional
/// placeholders** and `params` supplies one [`Value`] per placeholder, in order.
/// Values are bound out-of-band by the driver and are **never** interpolated into
/// the SQL text — that is what makes a moondb-based stack injection-safe all the
/// way to the wire.
///
/// The placeholder token itself is dialect-specific and chosen by the driver
/// (SQLite/MySQL use `?`, PostgreSQL uses `$1`, `$2`, …); a query layer that emits
/// SQL for a given backend uses that backend's token. moondb fixes the *calling
/// convention* (ordered params array), not the spelling.
///
/// * `execute` runs a statement that returns no rows (INSERT/UPDATE/DELETE/DDL) and
///   reports an [`ExecResult`].
/// * `query` runs a statement that returns rows and materialises every [`Row`].
/// * `begin` / `commit` / `rollback` bracket an explicit transaction. Nesting
///   (savepoints), isolation levels, and read-only hints are driver concerns layered
///   on top; the base contract is the three flat operations.
/// * `close` releases the connection. It does not raise: closing is best-effort and
///   idempotent, matching Go's `io.Closer` discipline for connections.
///
/// This trait is `pub(open)` so out-of-tree drivers (moon-sqlite, moon-postgres,
/// moon-mysql, …) can implement it. A future prepared-`Stmt` handle and a streaming
/// `Rows` cursor are noted in the README roadmap; v0.1 fixes exactly the operations
/// below so the contract everything pins to stays small and stable.
pub(open) trait Driver {
  /// Run a non-row statement with bound `params`; report rows changed and last id.
  fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  /// Run a row-returning statement with bound `params`; materialise every row.
  fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  /// Begin an explicit transaction.
  fn begin(Self) -> Unit raise DbError
  /// Commit the current transaction.
  fn commit(Self) -> Unit raise DbError
  /// Roll back the current transaction.
  fn rollback(Self) -> Unit raise DbError
  /// Release the underlying connection (best-effort, idempotent).
  fn close(Self) -> Unit
}
