// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A connection descriptor that carries the parameters needed to reach a
/// PostgreSQL backend and conforms to the synchronous [`@moondb.Driver`] seam.
///
/// ## The async wall (why this is a façade)
///
/// `@moondb.Driver`'s methods are **synchronous** (`fn execute(...) raise
/// DbError`), matching an FFI-backed driver like moon-sqlite whose C calls
/// block. PostgreSQL, however, is spoken over TCP, and MoonBit's only socket
/// stack (`moonbitlang/async`) is **async-only**: an `async fn` cannot be
/// called from a synchronous one, and the runtime exposes no public
/// "run-this-async-thunk-to-completion" bridge (`with_event_loop` lives in an
/// import-blocked `internal` package). A synchronous method therefore cannot
/// perform a PostgreSQL round trip.
///
/// The faithful, working driver is the **async [`PgConn`]** (see conn.mbt),
/// which mirrors asyncpg: `PgConn::connect` then `.execute` / `.query` /
/// `.begin` / `.commit` / `.rollback` / `.close`, all `async`, used inside an
/// event loop (`async test` / `async fn main`). The CI integration suite drives
/// a real PostgreSQL through exactly that API.
///
/// `PgDriver` exists to *demonstrate the seam* and to give moondb-based code a
/// stable target: it implements every `@moondb.Driver` method. The row-touching
/// methods raise a precise `ConnectError` explaining that the round trip must
/// run through `PgConn` under an event loop; `close` is a no-op. When moondb
/// grows an async `Driver` variant (or MoonBit ships a blocking socket / a
/// public event-loop entry), this façade becomes a thin adapter over `PgConn`
/// with no behavioural change to callers.
pub struct PgDriver {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
/// Build a driver descriptor. Does not connect — the async wall means the
/// actual connection is opened by [`PgConn::connect`] inside an event loop.
pub fn PgDriver::new(
  host~ : String,
  port? : Int = 5432,
  user~ : String,
  password? : String = "",
  database~ : String,
) -> PgDriver {
  { host, port, user, password, database }
}

///|
/// Open the async connection this descriptor points at. This is the intended
/// entry point: call it inside an event loop and use the returned [`PgConn`].
pub async fn PgDriver::connect(self : PgDriver) -> PgConn raise DbError {
  PgConn::connect(self.host, self.port, self.user, self.password, self.database)
}

///|
fn async_wall_error(op : String) -> DbError {
  @moondb.ConnectError(
    "PgDriver::" +
    op +
    " cannot run synchronously: PostgreSQL I/O is async under MoonBit. Use PgDriver::connect(...) / PgConn inside an event loop (async test / async fn main). See README §\"The async wall\".",
  )
}

///|
pub impl @moondb.Driver for PgDriver with fn execute(
  _self : PgDriver,
  _sql : String,
  _params : Array[Value],
) -> ExecResult raise DbError {
  raise async_wall_error("execute")
}

///|
pub impl @moondb.Driver for PgDriver with fn query(
  _self : PgDriver,
  _sql : String,
  _params : Array[Value],
) -> Array[Row] raise DbError {
  raise async_wall_error("query")
}

///|
pub impl @moondb.Driver for PgDriver with fn begin(_self : PgDriver) -> Unit raise DbError {
  raise async_wall_error("begin")
}

///|
pub impl @moondb.Driver for PgDriver with fn commit(_self : PgDriver) -> Unit raise DbError {
  raise async_wall_error("commit")
}

///|
pub impl @moondb.Driver for PgDriver with fn rollback(_self : PgDriver) -> Unit raise DbError {
  raise async_wall_error("rollback")
}

///|
pub impl @moondb.Driver for PgDriver with fn close(_self : PgDriver) -> Unit {

}
