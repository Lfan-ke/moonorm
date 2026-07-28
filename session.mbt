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
/// Whether `s` is a bare SQL identifier (`[A-Za-z_][A-Za-z0-9_]*`). SAVEPOINT names
/// are identifiers, not bound values, so they cannot be parameterised; validating
/// them keeps the nested-transaction API injection-safe by refusing anything that
/// is not a plain name.
fn is_ident(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    let alpha = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    let digit = c >= 48 && c <= 57
    if !(alpha || (i > 0 && digit)) {
      return false
    }
  }
  true
}

///|
/// Open a nested transaction with `SAVEPOINT <name>`. Savepoints nest arbitrarily,
/// so this is the faithful equivalent of SQLAlchemy's `Session.begin_nested()`:
/// work done after the savepoint can be undone with `rollback_to(name)` without
/// discarding the enclosing transaction, and finalised with `release(name)`.
///
/// `name` must be a bare identifier (it is interpolated as an identifier, never a
/// bound value); a non-identifier yields `QueryError` rather than reaching the
/// database.
pub fn[D : Driver] Session::savepoint(
  self : Session[D],
  name : String,
) -> Result[ExecResult, SqlError] {
  if !is_ident(name) {
    return Err(QueryError("invalid savepoint name: " + name))
  }
  self.driver.execute("SAVEPOINT " + name, [])
}

///|
/// Roll back to a savepoint (`ROLLBACK TO SAVEPOINT <name>`), undoing everything
/// done since it was opened while keeping the savepoint (and the outer transaction)
/// active. Rejects a non-identifier `name` with `QueryError`.
pub fn[D : Driver] Session::rollback_to(
  self : Session[D],
  name : String,
) -> Result[ExecResult, SqlError] {
  if !is_ident(name) {
    return Err(QueryError("invalid savepoint name: " + name))
  }
  self.driver.execute("ROLLBACK TO SAVEPOINT " + name, [])
}

///|
/// Release a savepoint (`RELEASE SAVEPOINT <name>`), merging its work into the
/// enclosing transaction (or savepoint). Rejects a non-identifier `name`.
pub fn[D : Driver] Session::release(
  self : Session[D],
  name : String,
) -> Result[ExecResult, SqlError] {
  if !is_ident(name) {
    return Err(QueryError("invalid savepoint name: " + name))
  }
  self.driver.execute("RELEASE SAVEPOINT " + name, [])
}

///|
/// Create the table backing `model` from its declared columns (see
/// `Model::create_table_sql`). With `if_not_exists=true` the DDL is idempotent.
pub fn[T, D : Driver] Session::create_table(
  self : Session[D],
  model : Model[T],
  if_not_exists? : Bool = false,
) -> Result[ExecResult, SqlError] {
  self.driver.execute(model.create_table_sql(if_not_exists~), [])
}

///|
/// Insert a mapped `record` through its `model`, binding the model's `to_columns`
/// pairs. Returns the affected-row count and new rowid.
pub fn[T, D : Driver] Session::insert_record(
  self : Session[D],
  model : Model[T],
  record : T,
) -> Result[ExecResult, SqlError] {
  let (sql, params) = model.insert_of(record).build()
  self.driver.execute(sql, params)
}

///|
/// Run a `Select` and decode every row into a `T` via `model`. Use it with a
/// `Model::select()` (optionally refined with `where_`/`order_by`) to get records
/// rather than raw `Row`s back.
pub fn[T, D : Driver] Session::fetch_as(
  self : Session[D],
  model : Model[T],
  stmt : Select,
) -> Result[Array[T], SqlError] {
  let (sql, params) = stmt.build()
  match self.driver.query(sql, params) {
    Ok(rows) => Ok(model.map_rows(rows))
    Err(e) => Err(e)
  }
}

///|
/// Fetch every row of a model's table, decoded into records (`SELECT <cols> FROM
/// <table>`).
pub fn[T, D : Driver] Session::all(
  self : Session[D],
  model : Model[T],
) -> Result[Array[T], SqlError] {
  self.fetch_as(model, model.select())
}

///|
/// Eagerly load the related records of a 1:N relationship: given a `source` parent,
/// run the relationship's query and decode every matching child into a record. This
/// is the explicit stand-in for SQLAlchemy's transparent lazy load (`parent.children`
/// firing a SELECT on attribute access) — MoonBit has no attribute interception, so
/// the load is a call, exactly as Diesel and GORM require. The match value is bound,
/// so eager loading stays injection-safe.
pub fn[S, T, D : Driver] Session::load(
  self : Session[D],
  source : S,
  rel : Relation[S, T],
) -> Result[Array[T], SqlError] {
  let (sql, params) = rel.query(source).build()
  match self.driver.query(sql, params) {
    Ok(rows) => Ok(rel.target.map_rows(rows))
    Err(e) => Err(e)
  }
}

///|
/// Eagerly load the single related record of a N:1 relationship (e.g. a child's
/// parent): the first matching row decoded into a record, or `None` if there is no
/// match. Like `load`, the match value is bound.
pub fn[S, T, D : Driver] Session::load_one(
  self : Session[D],
  source : S,
  rel : Relation[S, T],
) -> Result[T?, SqlError] {
  let (sql, params) = rel.query(source).limit(1).build()
  match self.driver.query(sql, params) {
    Ok(rows) =>
      if rows.length() == 0 {
        Ok(None)
      } else {
        Ok(Some(rel.target.map_row(rows[0])))
      }
    Err(e) => Err(e)
  }
}

///|
/// Close the session's underlying connection.
pub fn[D : Driver] Session::close(self : Session[D]) -> Unit {
  self.driver.close()
}
