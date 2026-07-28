// The execution layer: an explicit `Session` that runs the query builder's
// statements against any `@moondb.Driver` and hands back typed rows. moonorm owns
// no driver contract of its own — the seam is `@moondb`, so a `Session` drives a
// SQLite backend (moon-sqlite), a Postgres backend, or the dependency-free
// `@moondb.MockDriver` interchangeably. Values still travel as bound parameters end
// to end, so the injection-safety guarantee reaches all the way to the wire.

///|
/// An explicit unit-of-work over a `@moondb.Driver`. Unlike SQLAlchemy's implicit
/// autoflush and attribute-triggered SQL, every statement here is issued explicitly
/// — the faithful MoonBit equivalent given the absence of attribute interception,
/// exactly as Diesel and GORM also require. It holds the backend as a
/// `&@moondb.Driver` trait object, so one `Session` type drives every backend.
pub struct Session {
  driver : &@moondb.Driver
}

///|
/// Wrap a connected driver in a session.
pub fn Session::new(driver : &@moondb.Driver) -> Session {
  { driver, }
}

///|
/// Execute a raw statement with bound `params`.
pub fn Session::execute(
  self : Session,
  sql : String,
  params : Array[Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
/// Run a raw query with bound `params` and return its rows.
pub fn Session::query(
  self : Session,
  sql : String,
  params : Array[Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
/// Build and run an `Insert`, returning the affected-row count and new rowid.
pub fn Session::add(
  self : Session,
  stmt : Insert,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Select`, returning the matched rows.
pub fn Session::fetch(
  self : Session,
  stmt : Select,
) -> Array[@moondb.Row] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.query(sql, params)
}

///|
/// Build and run an `Update`, returning the affected-row count.
pub fn Session::modify(
  self : Session,
  stmt : Update,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Build and run a `Delete`, returning the affected-row count.
pub fn Session::remove(
  self : Session,
  stmt : Delete,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = stmt.build()
  self.driver.execute(sql, params)
}

///|
/// Begin an explicit transaction. Delegates to the driver's transaction bracket
/// (`@moondb.Driver::begin`) rather than emitting `BEGIN` as text, so a driver that
/// manages transactions out-of-band (or maps them to savepoints) stays in control.
pub fn Session::begin(self : Session) -> Unit raise @moondb.DbError {
  self.driver.begin()
}

///|
/// Commit the current transaction.
pub fn Session::commit(self : Session) -> Unit raise @moondb.DbError {
  self.driver.commit()
}

///|
/// Roll back the current transaction.
pub fn Session::rollback(self : Session) -> Unit raise @moondb.DbError {
  self.driver.rollback()
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
/// bound value); a non-identifier raises `QueryError` rather than reaching the
/// database. The statement is issued through `execute`, so a backend that supports
/// SQL savepoints (SQLite, Postgres) runs it verbatim.
pub fn Session::savepoint(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("SAVEPOINT " + name, [])
}

///|
/// Roll back to a savepoint (`ROLLBACK TO SAVEPOINT <name>`), undoing everything
/// done since it was opened while keeping the savepoint (and the outer transaction)
/// active. Rejects a non-identifier `name` with `QueryError`.
pub fn Session::rollback_to(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("ROLLBACK TO SAVEPOINT " + name, [])
}

///|
/// Release a savepoint (`RELEASE SAVEPOINT <name>`), merging its work into the
/// enclosing transaction (or savepoint). Rejects a non-identifier `name`.
pub fn Session::release(
  self : Session,
  name : String,
) -> @moondb.ExecResult raise @moondb.DbError {
  if !is_ident(name) {
    raise @moondb.QueryError("invalid savepoint name: " + name)
  }
  self.driver.execute("RELEASE SAVEPOINT " + name, [])
}

///|
/// Create the table backing `model` from its declared columns (see
/// `Model::create_table_sql`). With `if_not_exists=true` the DDL is idempotent.
pub fn[T] Session::create_table(
  self : Session,
  model : Model[T],
  if_not_exists? : Bool = false,
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(model.create_table_sql(if_not_exists~), [])
}

///|
/// Insert a mapped `record` through its `model`, binding the model's `to_columns`
/// pairs. Returns the affected-row count and new rowid.
pub fn[T] Session::insert_record(
  self : Session,
  model : Model[T],
  record : T,
) -> @moondb.ExecResult raise @moondb.DbError {
  let (sql, params) = model.insert_of(record).build()
  self.driver.execute(sql, params)
}

///|
/// Run a `Select` and decode every row into a `T` via `model`. Use it with a
/// `Model::select()` (optionally refined with `where_`/`order_by`) to get records
/// rather than raw `Row`s back.
pub fn[T] Session::fetch_as(
  self : Session,
  model : Model[T],
  stmt : Select,
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = stmt.build()
  model.map_rows(self.driver.query(sql, params))
}

///|
/// Fetch every row of a model's table, decoded into records (`SELECT <cols> FROM
/// <table>`).
pub fn[T] Session::all(
  self : Session,
  model : Model[T],
) -> Array[T] raise @moondb.DbError {
  self.fetch_as(model, model.select())
}

///|
/// Eagerly load the related records of a 1:N relationship: given a `source` parent,
/// run the relationship's query and decode every matching child into a record. This
/// is the explicit stand-in for SQLAlchemy's transparent lazy load (`parent.children`
/// firing a SELECT on attribute access) — MoonBit has no attribute interception, so
/// the load is a call, exactly as Diesel and GORM require. The match value is bound,
/// so eager loading stays injection-safe.
pub fn[S, T] Session::load(
  self : Session,
  source : S,
  rel : Relation[S, T],
) -> Array[T] raise @moondb.DbError {
  let (sql, params) = rel.query(source).build()
  rel.target.map_rows(self.driver.query(sql, params))
}

///|
/// Eagerly load the single related record of a N:1 relationship (e.g. a child's
/// parent): the first matching row decoded into a record, or `None` if there is no
/// match. Like `load`, the match value is bound.
pub fn[S, T] Session::load_one(
  self : Session,
  source : S,
  rel : Relation[S, T],
) -> T? raise @moondb.DbError {
  let (sql, params) = rel.query(source).limit(1).build()
  let rows = self.driver.query(sql, params)
  if rows.length() == 0 {
    None
  } else {
    Some(rel.target.map_row(rows[0]))
  }
}

///|
/// Close the session's underlying connection.
pub fn Session::close(self : Session) -> Unit {
  self.driver.close()
}
