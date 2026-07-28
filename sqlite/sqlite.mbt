// The native SQLite backend: a real connection to a real SQLite database via the
// vendored amalgamation. It implements `@moonorm.Driver`, so the query builder and
// `Session` run against it unchanged. Bound parameters map to SQLite's storage
// classes; result columns decode back into `@moonorm.Value` by their runtime type.

///|
/// A live connection to a SQLite database. Open it with `SqliteConn::open`; it
/// satisfies `@moonorm.Driver`, so a `@moonorm.Session` can drive it directly.
pub struct SqliteConn {
  handle : Int64
}

///|
/// Open (or create) the database at `path`. Use `":memory:"` for a private
/// in-memory database. Returns `ConnectError` if the file cannot be opened.
pub fn SqliteConn::open(path : String) -> Result[SqliteConn, @moonorm.SqlError] {
  let h = ffi_open(@utf8.encode(path))
  if h == 0L {
    Err(@moonorm.ConnectError("cannot open database: " + path))
  } else {
    Ok({ handle: h })
  }
}

///|
/// Run a semicolon-separated script (e.g. a schema DDL block) in one call. Unlike
/// `execute`, this uses SQLite's multi-statement `exec` path and binds no
/// parameters. Returns `QueryError` with SQLite's message on failure.
pub fn SqliteConn::exec_script(
  self : SqliteConn,
  script : String,
) -> Result[Unit, @moonorm.SqlError] {
  let rc = ffi_exec(self.handle, @utf8.encode(script))
  if rc != 0 {
    Err(@moonorm.QueryError(bytes_to_str(ffi_errmsg(self.handle))))
  } else {
    Ok(())
  }
}

///|
fn bytes_to_str(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => ""
  }
}

///|
fn bind_params(st : Int64, params : Array[@moonorm.Value]) -> Unit {
  for i = 0; i < params.length(); i = i + 1 {
    let idx = i + 1
    match params[i] {
      @moonorm.Int(v) => ffi_bind_int(st, idx, v) |> ignore
      @moonorm.Int64(v) => ffi_bind_int64(st, idx, v) |> ignore
      @moonorm.Double(v) => ffi_bind_double(st, idx, v) |> ignore
      @moonorm.Text(v) => ffi_bind_text(st, idx, @utf8.encode(v)) |> ignore
      @moonorm.Bool(v) => ffi_bind_int(st, idx, if v { 1 } else { 0 }) |> ignore
      @moonorm.Null => ffi_bind_null(st, idx) |> ignore
    }
  }
}

///|
pub impl @moonorm.Driver for SqliteConn with fn execute(self, sql, params) {
  let st = ffi_prepare(self.handle, @utf8.encode(sql))
  if st == 0L {
    return Err(QueryError(bytes_to_str(ffi_errmsg(self.handle))))
  }
  bind_params(st, params)
  let rc = ffi_step(st)
  ffi_finalize(st) |> ignore
  if rc != sqlite_done && rc != sqlite_row {
    return Err(@moonorm.QueryError(bytes_to_str(ffi_errmsg(self.handle))))
  }
  Ok({
    rows_affected: ffi_changes(self.handle),
    last_insert_id: ffi_last_id(self.handle),
  })
}

///|
pub impl @moonorm.Driver for SqliteConn with fn query(self, sql, params) {
  let st = ffi_prepare(self.handle, @utf8.encode(sql))
  if st == 0L {
    return Err(@moonorm.QueryError(bytes_to_str(ffi_errmsg(self.handle))))
  }
  bind_params(st, params)
  let ncol = ffi_col_count(st)
  let cols : Array[String] = []
  for i = 0; i < ncol; i = i + 1 {
    cols.push(bytes_to_str(ffi_col_name(st, i)))
  }
  let rows : Array[@moonorm.Row] = []
  for ;; {
    let rc = ffi_step(st)
    if rc != sqlite_row {
      break
    }
    let vals : Array[@moonorm.Value] = []
    for i = 0; i < ncol; i = i + 1 {
      // SQLite column types: 1=INTEGER 2=FLOAT 3=TEXT 4=BLOB 5=NULL.
      let v : @moonorm.Value = match ffi_col_type(st, i) {
        1 => @moonorm.Int64(ffi_col_int64(st, i))
        2 => @moonorm.Double(ffi_col_double(st, i))
        3 => @moonorm.Text(bytes_to_str(ffi_col_text(st, i)))
        _ => @moonorm.Null
      }
      vals.push(v)
    }
    rows.push({ columns: cols, values: vals })
  }
  ffi_finalize(st) |> ignore
  Ok(rows)
}

///|
pub impl @moonorm.Driver for SqliteConn with fn close(self) {
  ffi_close(self.handle) |> ignore
}
