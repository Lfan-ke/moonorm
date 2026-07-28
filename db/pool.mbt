// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A fixed-ceiling connection pool over any [`Driver`]. Opening a database
/// connection is expensive — a TCP handshake and auth round trip for a networked
/// backend — so a server hands out a small set of connections and reuses them
/// instead of opening one per request. This is the moondb counterpart of Go's
/// `sql.DB` connection pool and SQLAlchemy's `QueuePool`.
///
/// The pool is generic in the concrete driver `D` rather than holding
/// `&Driver` trait objects, so `acquire` gives back the real driver type and a
/// caller keeps access to backend-specific methods (SQLite's `exec_script`, a
/// driver's prepared-statement handle). `new` takes a `make` factory that opens
/// one fresh connection; the pool calls it only when no idle connection is
/// available and the open count is still below `max_size`.
///
/// It is synchronous and single-threaded by design — moondb's base contract is
/// sync, and MoonBit's pure backends have no shared-memory threads — so `acquire`
/// never blocks: a request that finds the pool exhausted raises `QueryError`
/// rather than waiting. A driver that runs on an async runtime layers waiting on
/// top; the reuse, ceiling, and lifecycle bookkeeping live here.
pub struct Pool[D] {
  make : () -> D raise DbError
  idle : Array[D]
  mut open_count : Int
  max_size : Int
  mut closed : Bool
}

///|
/// Build a pool whose connections come from `make`. `max_size` caps how many
/// connections may be open at once (in use plus idle); it defaults to 10, the
/// same ceiling Go's `database/sql` uses out of the box. `max_size` must be
/// positive.
pub fn[D] Pool::new(
  make : () -> D raise DbError,
  max_size? : Int = 10,
) -> Pool[D] raise DbError {
  if max_size <= 0 {
    raise QueryError(
      "pool max_size must be positive, got " + max_size.to_string(),
    )
  }
  { make, idle: [], open_count: 0, max_size, closed: false }
}

///|
/// How many connections are currently idle (checked in and reusable).
pub fn[D] Pool::idle_count(self : Pool[D]) -> Int {
  self.idle.length()
}

///|
/// How many connections the pool has open in total: those checked out plus those
/// sitting idle. Never exceeds `max_size`.
pub fn[D] Pool::open_count(self : Pool[D]) -> Int {
  self.open_count
}

///|
/// The pool's ceiling on simultaneously open connections.
pub fn[D] Pool::max_size(self : Pool[D]) -> Int {
  self.max_size
}

///|
/// Whether [`close_all`] has been called.
pub fn[D] Pool::is_closed(self : Pool[D]) -> Bool {
  self.closed
}

///|
/// Take a connection: reuse an idle one if the pool has any (the common path,
/// avoiding a fresh handshake), otherwise open a new one through `make` as long
/// as the open count is below `max_size`. Raises `QueryError` if the pool is
/// exhausted (all `max_size` connections are checked out) or has been closed.
/// The caller must return the connection with [`release`] — or use [`with`],
/// which does so even on error.
pub fn[D] Pool::acquire(self : Pool[D]) -> D raise DbError {
  if self.closed {
    raise Closed
  }
  match self.idle.pop() {
    Some(c) => c
    None => {
      if self.open_count >= self.max_size {
        raise QueryError(
          "connection pool exhausted (max_size=" +
          self.max_size.to_string() +
          ")",
        )
      }
      let c = (self.make)()
      self.open_count = self.open_count + 1
      c
    }
  }
}

///|
/// Return a connection to the idle set so a later [`acquire`] can reuse it. A
/// connection released back into a closed pool is closed immediately rather than
/// pooled, so no handle outlives `close_all`.
pub fn[D : Driver] Pool::release(self : Pool[D], conn : D) -> Unit {
  if self.closed {
    conn.close()
    self.open_count = self.open_count - 1
    return
  }
  self.idle.push(conn)
}

///|
/// Run `f` with a pooled connection, returning it afterwards whether `f` returns
/// or raises. This is the leak-proof way to use the pool: the `release` happens
/// on every path, so a raising query never strands a connection checked out.
pub fn[D : Driver, R] Pool::with_conn(
  self : Pool[D],
  f : (D) -> R raise DbError,
) -> R raise DbError {
  let conn = self.acquire()
  let r = f(conn) catch {
    e => {
      self.release(conn)
      raise e
    }
  }
  self.release(conn)
  r
}

///|
/// Close every idle connection and mark the pool closed. Connections still
/// checked out are not touched — the pool does not track them individually — but
/// each is closed as it is [`release`]d back. After this, `acquire` raises
/// `Closed`. Idempotent.
pub fn[D : Driver] Pool::close_all(self : Pool[D]) -> Unit {
  for c in self.idle {
    c.close()
  }
  self.open_count = self.open_count - self.idle.length()
  self.idle.clear()
  self.closed = true
}
