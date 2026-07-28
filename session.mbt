// The execution layer: a backend-agnostic `Driver` trait plus an explicit
// `Session` that runs the query builder's statements against a real database and
// hands back typed rows. Backends (e.g. the native SQLite driver in the `sqlite`
// sub-package) implement `Driver`; the builder and this layer stay pure so they
// compile on every backend. Values still travel as bound parameters end to end,
// so the injection-safety guarantee reaches all the way to the wire.

///|
/// One row of a result set: the column names (in projection order) alongside the
/// decoded `Value` for each. `columns` and `values` are the same length.
pub(all) struct Row {
  columns : Array[String]
  values : Array[Value]
}

///|
/// The raw `Value` at column `idx` (0-based, projection order).
pub fn Row::get(self : Row, idx : Int) -> Value {
  self.values[idx]
}

///|
/// The `Value` of the column named `name`, or `None` if no such column was
/// projected. Names are matched exactly as the database reported them.
pub fn Row::by_name(self : Row, name : String) -> Value? {
  for i = 0; i < self.columns.length(); i = i + 1 {
    if self.columns[i] == name {
      return Some(self.values[i])
    }
  }
  None
}

///|
/// Read column `idx` as an `Int`, narrowing an `Int64` when needed. `None` if the
/// column is not an integer.
pub fn Row::int(self : Row, idx : Int) -> Int? {
  match self.values[idx] {
    Int(v) => Some(v)
    Int64(v) => Some(v.to_int())
    Bool(v) => Some(if v { 1 } else { 0 })
    _ => None
  }
}

///|
/// Read column `idx` as an `Int64`. `None` if the column is not an integer.
pub fn Row::int64(self : Row, idx : Int) -> Int64? {
  match self.values[idx] {
    Int64(v) => Some(v)
    Int(v) => Some(v.to_int64())
    _ => None
  }
}

///|
/// Read column `idx` as text. `None` if the column is not TEXT.
pub fn Row::text(self : Row, idx : Int) -> String? {
  match self.values[idx] {
    Text(v) => Some(v)
    _ => None
  }
}

///|
/// Read column `idx` as a `Double`, widening an integer when needed. `None` if the
/// column is not numeric.
pub fn Row::double(self : Row, idx : Int) -> Double? {
  match self.values[idx] {
    Double(v) => Some(v)
    Int(v) => Some(v.to_double())
    Int64(v) => Some(v.to_double())
    _ => None
  }
}

///|
/// The outcome of a non-query statement: how many rows it changed and the rowid
/// of the last inserted row (backend-defined; `0` when not applicable).
pub(all) struct ExecResult {
  rows_affected : Int
  last_insert_id : Int64
}

///|
/// A database-layer failure. `ConnectError` covers opening/attaching a connection;
/// `QueryError` carries the backend's message for a failed prepare/step/bind.
pub(all) enum SqlError {
  ConnectError(String)
  QueryError(String)
} derive(Eq)

///|
/// Render a `SqlError` for logs and test output.
pub fn SqlError::to_string(self : SqlError) -> String {
  match self {
    ConnectError(m) => "ConnectError: " + m
    QueryError(m) => "QueryError: " + m
  }
}

///|
pub impl Show for SqlError with fn output(self : SqlError, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
/// A database backend. A driver turns a `(sql, params)` pair — exactly what the
/// query builder emits — into either an `ExecResult` (for INSERT/UPDATE/DELETE/DDL)
/// or a set of `Row`s (for SELECT). Parameters are bound out-of-band, never spliced
/// into the SQL. This is the faithful equivalent of SQLAlchemy's DBAPI/dialect
/// seam: the builder is dialect-neutral, each backend adapts the wire.
pub(open) trait Driver {
  /// Run a statement that returns no rows; report affected-row count and last id.
  fn execute(Self, String, Array[Value]) -> Result[ExecResult, SqlError]
  /// Run a query and materialise every result row.
  fn query(Self, String, Array[Value]) -> Result[Array[Row], SqlError]
  /// Release the underlying connection.
  fn close(Self) -> Unit
}

///|
/// An explicit unit-of-work over a `Driver`. Unlike SQLAlchemy's implicit autoflush
/// and attribute-triggered SQL, every statement here is issued explicitly — the
/// faithful MoonBit equivalent given the absence of attribute interception, exactly
/// as Diesel and GORM also require. `Session` is generic over the backend, so it
/// carries no dynamic dispatch cost.
pub struct Session[D] {
  driver : D
}

///|
/// Wrap a connected driver in a session.
pub fn[D] Session::new(driver : D) -> Session[D] {
  { driver, }
}

///|
/// Execute a raw statement with bound `params`.
pub fn[D : Driver] Session::execute(
  self : Session[D],
  sql : String,
  params : Array[Value],
) -> Result[ExecResult, SqlError] {
  self.driver.execute(sql, params)
}

///|
/// Run a raw query with bound `params` and return its rows.
pub fn[D : Driver] Session::query(
  self : Session[D],
  sql : String,
  params : Array[Value],
) -> Result[Array[Row], SqlError] {
  self.driver.query(sql, params)
}

///|
/// Build and run an `Insert`, returning the affected-row count and new rowid.
pub fn[D : Driver] Session::add(
  self : Session[D],
  stmt : Insert,
) -> Result[ExecResult, SqlError] {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Select`, returning the matched rows.
pub fn[D : Driver] Session::fetch(
  self : Session[D],
  stmt : Select,
) -> Result[Array[Row], SqlError] {
  let (sql, params) = stmt.build()
  self.driver.query(sql, params)
}

///|
/// Build and run an `Update`, returning the affected-row count.
pub fn[D : Driver] Session::modify(
  self : Session[D],
  stmt : Update,
) -> Result[ExecResult, SqlError] {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Delete`, returning the affected-row count.
pub fn[D : Driver] Session::remove(
  self : Session[D],
  stmt : Delete,
) -> Result[ExecResult, SqlError] {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Begin an explicit transaction (`BEGIN`).
pub fn[D : Driver] Session::begin(
  self : Session[D],
) -> Result[ExecResult, SqlError] {
  self.driver.execute("BEGIN", [])
}

///|
/// Commit the current transaction (`COMMIT`).
pub fn[D : Driver] Session::commit(
  self : Session[D],
) -> Result[ExecResult, SqlError] {
  self.driver.execute("COMMIT", [])
}

///|
/// Roll back the current transaction (`ROLLBACK`).
pub fn[D : Driver] Session::rollback(
  self : Session[D],
) -> Result[ExecResult, SqlError] {
  self.driver.execute("ROLLBACK", [])
}

///|
/// Close the session's underlying connection.
pub fn[D : Driver] Session::close(self : Session[D]) -> Unit {
  self.driver.close()
}
