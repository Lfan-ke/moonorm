// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The pool exercised against the MockDriver test double. `MockDriver::new` is the
// factory; a counter cell records how many real connections the pool opens, which
// is what proves idle reuse (acquire after release must not open a second one) and
// the max_size ceiling. Mutation check: making `acquire` always call `make` instead
// of reusing an idle connection turns the reuse and open-count assertions red.

///|
/// A factory that counts how many connections it has opened, and the pool over it.
/// The count lives in a one-cell array so the closure can mutate it.
fn counting_pool(
  max_size? : Int = 10,
) -> (Pool[MockDriver], Array[Int]) raise DbError {
  let opened = [0]
  let pool = Pool::new(
    () => {
      opened[0] = opened[0] + 1
      MockDriver::new()
    },
    max_size~,
  )
  (pool, opened)
}

///|
test "pool: an idle connection is reused, not reopened" {
  let (pool, opened) = counting_pool()
  let a = pool.acquire()
  assert_eq(opened[0], 1)
  assert_eq(pool.open_count(), 1)
  assert_eq(pool.idle_count(), 0)
  pool.release(a)
  assert_eq(pool.idle_count(), 1)
  // The second acquire must hand back the released connection — no new open.
  let b = pool.acquire()
  assert_eq(opened[0], 1)
  assert_eq(pool.open_count(), 1)
  assert_eq(pool.idle_count(), 0)
  pool.release(b)
}

///|
test "pool: opens up to max_size distinct connections, then exhausts" {
  let (pool, opened) = counting_pool(max_size=2)
  let a = pool.acquire()
  let b = pool.acquire()
  assert_eq(opened[0], 2)
  assert_eq(pool.open_count(), 2)
  // A third concurrent checkout has no idle connection and no headroom.
  let exhausted = try {
    pool.acquire() |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(exhausted, true)
  // Returning one frees a slot; the next acquire reuses it (still only 2 opened).
  pool.release(a)
  let c = pool.acquire()
  assert_eq(opened[0], 2)
  assert_eq(c.row_count(), 0)
  pool.release(b)
  pool.release(c)
}

///|
test "pool: with_conn releases on the success path" {
  let (pool, _) = counting_pool()
  let n = pool.with_conn(db => {
    db.execute("INSERT INTO t VALUES (?)", [Int(1)]) |> ignore
    db.row_count()
  })
  assert_eq(n, 1)
  // The connection went back to the pool, so it is idle again.
  assert_eq(pool.idle_count(), 1)
  assert_eq(pool.open_count(), 1)
}

///|
test "pool: with_conn releases even when the body raises" {
  let (pool, opened) = counting_pool()
  let raised = try {
    let _ : Unit = pool.with_conn(db => {
      db.execute("x", [Int(1)]) |> ignore
      raise QueryError("boom")
    })
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(raised, true)
  // Despite the raise, the connection was returned — reusable, not leaked.
  assert_eq(pool.idle_count(), 1)
  assert_eq(opened[0], 1)
}

///|
test "pool: close_all closes idle connections and refuses further acquire" {
  let (pool, _) = counting_pool()
  let a = pool.acquire()
  let b = pool.acquire()
  pool.release(a)
  pool.release(b)
  assert_eq(pool.idle_count(), 2)
  pool.close_all()
  assert_eq(pool.is_closed(), true)
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.open_count(), 0)
  let refused = try {
    pool.acquire() |> ignore
    false
  } catch {
    Closed => true
    _ => false
  }
  assert_eq(refused, true)
}

///|
test "pool: a connection released after close is closed, not pooled" {
  let (pool, _) = counting_pool()
  let a = pool.acquire()
  pool.close_all()
  // `a` was checked out during close_all, so it survived; releasing it now must
  // close it (open_count drops) rather than re-add it to a closed pool.
  assert_eq(a.is_closed(), false)
  pool.release(a)
  assert_eq(a.is_closed(), true)
  assert_eq(pool.idle_count(), 0)
  assert_eq(pool.open_count(), 0)
}

///|
test "pool: max_size must be positive" {
  let bad = try {
    Pool::new(() => MockDriver::new(), max_size=0) |> ignore
    false
  } catch {
    QueryError(_) => true
    _ => false
  }
  assert_eq(bad, true)
}
