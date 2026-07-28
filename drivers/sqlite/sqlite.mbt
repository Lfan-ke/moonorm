// The native SQLite backend for moondb: a real connection to a real SQLite database
// via the vendored amalgamation. `SqliteDriver` implements `@moondb.Driver`, so any
// moondb-based query layer — moonorm's `Session`, a hand-written statement, anything
// pinned to the interface — runs against SQLite unchanged. Bound parameters map to
// SQLite's storage classes; result columns decode back into `@moondb.Value` by their
// runtime type. This is the only C-touching package in the moondb/moonorm stack: the
// amalgamation lives here, isolated, so everything above it stays pure MoonBit.

///|
/// A live connection to a SQLite database. Open it with `SqliteDriver::open`; it
/// implements `@moondb.Driver`, so a moondb query layer can drive it directly. The
/// opaque `sqlite3*` is carried as its pointer bits in `handle`.
pub struct SqliteDriver {
  handle : Int64
}

///|
/// Open (or create) the database at `path`. Use `":memory:"` for a private in-memory
/// database. Raises `@moondb.ConnectError` if the file cannot be opened.
pub fn SqliteDriver::open(path : String) -> SqliteDriver raise @moondb.DbError {
  let h = ffi_open(@utf8.encode(path))
  if h == 0L {
    raise @moondb.ConnectError("cannot open database: " + path)
  }
  { handle: h }
}

///|
/// Run a semicolon-separated script (e.g. a schema DDL block) in one call. Unlike
/// `execute`, this uses SQLite's multi-statement `exec` path and binds no parameters.
/// Raises `@moondb.QueryError` with SQLite's message on failure.
pub fn SqliteDriver::exec_script(
  self : SqliteDriver,
  script : String,
) -> Unit raise @moondb.DbError {
  let rc = ffi_exec(self.handle, @utf8.encode(script))
  if rc != 0 {
    raise @moondb.QueryError(bytes_to_str(ffi_errmsg(self.handle)))
  }
}

///|
fn bytes_to_str(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => ""
  }
}

///|
/// Bind each `@moondb.Value` to its 1-based SQLite parameter slot. Every variant maps
/// to a SQLite storage class out-of-band — nothing is ever spliced into the SQL text.
fn bind_params(st : Int64, params : Array[@moondb.Value]) -> Unit {
  for i = 0; i < params.length(); i = i + 1 {
    let idx = i + 1
    match params[i] {
      @moondb.Null => ffi_bind_null(st, idx) |> ignore
      @moondb.Bool(v) => ffi_bind_int(st, idx, if v { 1 } else { 0 }) |> ignore
      @moondb.Int(v) => ffi_bind_int(st, idx, v) |> ignore
      @moondb.Int64(v) => ffi_bind_int64(st, idx, v) |> ignore
      @moondb.Double(v) => ffi_bind_double(st, idx, v) |> ignore
      @moondb.Text(v) => ffi_bind_text(st, idx, @utf8.encode(v)) |> ignore
      @moondb.Blob(v) => ffi_bind_blob(st, idx, v) |> ignore
    }
  }
}

///|
/// Prepare + bind, returning the statement handle or raising `QueryError` with
/// SQLite's message if the prepare failed.
fn SqliteDriver::prepare_bound(
  self : SqliteDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Int64 raise @moondb.DbError {
  let st = ffi_prepare(self.handle, @utf8.encode(sql))
  if st == 0L {
    raise @moondb.QueryError(bytes_to_str(ffi_errmsg(self.handle)))
  }
  bind_params(st, params)
  st
}

///|
pub impl @moondb.Driver for SqliteDriver with fn execute(self, sql, params) {
  let st = self.prepare_bound(sql, params)
  let rc = ffi_step(st)
  ffi_finalize(st) |> ignore
  if rc != sqlite_done && rc != sqlite_row {
    raise @moondb.QueryError(bytes_to_str(ffi_errmsg(self.handle)))
  }
  {
    rows_affected: ffi_changes(self.handle).to_int64(),
    last_insert_id: ffi_last_id(self.handle),
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn query(self, sql, params) {
  let st = self.prepare_bound(sql, params)
  let ncol = ffi_col_count(st)
  let cols : Array[String] = []
  for i = 0; i < ncol; i = i + 1 {
    cols.push(bytes_to_str(ffi_col_name(st, i)))
  }
  let rows : Array[@moondb.Row] = []
  for ;; {
    let rc = ffi_step(st)
    if rc != sqlite_row {
      break
    }
    let vals : Array[@moondb.Value] = []
    for i = 0; i < ncol; i = i + 1 {
      // SQLite column types: 1=INTEGER 2=FLOAT 3=TEXT 4=BLOB 5=NULL.
      let v : @moondb.Value = match ffi_col_type(st, i) {
        1 => @moondb.Int64(ffi_col_int64(st, i))
        2 => @moondb.Double(ffi_col_double(st, i))
        3 => @moondb.Text(bytes_to_str(ffi_col_text(st, i)))
        4 => @moondb.Blob(ffi_col_blob(st, i))
        _ => @moondb.Null
      }
      vals.push(v)
    }
    rows.push({ columns: cols, values: vals })
  }
  ffi_finalize(st) |> ignore
  rows
}

///|
pub impl @moondb.Driver for SqliteDriver with fn begin(self) {
  self.run_txn("BEGIN")
}

///|
pub impl @moondb.Driver for SqliteDriver with fn commit(self) {
  self.run_txn("COMMIT")
}

///|
pub impl @moondb.Driver for SqliteDriver with fn rollback(self) {
  self.run_txn("ROLLBACK")
}

///|
/// Run a transaction-control keyword through SQLite's `exec` path, raising
/// `QueryError` with the backend message on failure.
fn SqliteDriver::run_txn(
  self : SqliteDriver,
  kw : String,
) -> Unit raise @moondb.DbError {
  let rc = ffi_exec(self.handle, @utf8.encode(kw))
  if rc != 0 {
    raise @moondb.QueryError(bytes_to_str(ffi_errmsg(self.handle)))
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn close(self) {
  ffi_close(self.handle) |> ignore
}
