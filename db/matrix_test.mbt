// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The completeness matrix for the moondb surface: every Value variant through
// kind/is_null/Show/Eq (including boundaries and cross-variant inequality), every
// Row accessor by name as well as by position (widening, narrowing, NULL-as-
// TypeError, missing-name QueryError), every DbError case through Show, and the
// MockDriver transaction edges the per-file tests do not reach. These run on every
// backend under `--target all`.

// --- Value: every variant, every projection ------------------------------------

///|
test "value: kind covers all seven variants at their boundaries" {
  assert_eq(Value::Null.kind(), "Null")
  assert_eq(Value::Bool(false).kind(), "Bool")
  assert_eq(Value::Int(0).kind(), "Int")
  assert_eq(Value::Int(2147483647).kind(), "Int")
  assert_eq(Value::Int64(-9223372036854775807L - 1L).kind(), "Int64")
  assert_eq(Value::Double(0.0).kind(), "Double")
  assert_eq(Value::Text("").kind(), "Text")
  assert_eq(Value::Blob(b"").kind(), "Blob")
}

///|
test "value: is_null is true only for Null, across every other variant" {
  assert_eq(Value::Null.is_null(), true)
  assert_eq(Value::Bool(false).is_null(), false)
  assert_eq(Value::Int(0).is_null(), false)
  assert_eq(Value::Int64(0).is_null(), false)
  assert_eq(Value::Double(0.0).is_null(), false)
  assert_eq(Value::Text("").is_null(), false)
  assert_eq(Value::Blob(b"").is_null(), false)
}

///|
test "value: Show renders every variant, quoting text and hiding blob bytes" {
  assert_eq("\{Value::Null}", "Null")
  assert_eq("\{Value::Bool(true)}", "Bool(true)")
  assert_eq("\{Value::Bool(false)}", "Bool(false)")
  assert_eq("\{Value::Int(-1)}", "Int(-1)")
  assert_eq("\{Value::Int64(9000000000L)}", "Int64(9000000000)")
  assert_eq("\{Value::Double(2.5)}", "Double(2.5)")
  assert_eq("\{Value::Text("")}", "Text(\"\")")
  assert_eq("\{Value::Text("a\"b")}", "Text(\"a\"b\")")
  assert_eq("\{Value::Blob(b"")}", "Blob(0 bytes)")
  assert_eq("\{Value::Blob(b"\x01\x02\x03\x04")}", "Blob(4 bytes)")
}

///|
test "value: equality is per-variant and never crosses variants" {
  // Same variant, equal payloads.
  assert_eq(Value::Bool(true) == Value::Bool(true), true)
  assert_eq(Value::Int64(5) == Value::Int64(5), true)
  assert_eq(Value::Double(1.5) == Value::Double(1.5), true)
  assert_eq(Value::Blob(b"") == Value::Blob(b""), true)
  // Same variant, different payloads.
  assert_eq(Value::Bool(true) == Value::Bool(false), false)
  assert_eq(Value::Double(1.5) == Value::Double(1.6), false)
  assert_eq(Value::Text("a") == Value::Text("b"), false)
  // A 32-bit Int and a 64-bit Int64 of the same magnitude are distinct values —
  // the driver decides which a column decodes to, and the two never compare equal.
  assert_eq(Value::Int(5) == Value::Int64(5), false)
  // Null equals only Null.
  assert_eq(Value::Null == Value::Null, true)
  assert_eq(Value::Null == Value::Int(0), false)
  assert_eq(Value::Null == Value::Bool(false), false)
}

// --- Row: by-name accessors match the positional matrix ------------------------

///|
fn typed_row() -> Row {
  {
    columns: ["b", "i", "big", "d", "t", "raw", "n"],
    values: [
      Bool(true),
      Int(42),
      Int64(9000000000),
      Double(3.5),
      Text("hi"),
      Blob(b"\xde\xad"),
      Value::Null,
    ],
  }
}

///|
test "row: every by-name typed accessor reads its declared type" {
  let r = typed_row()
  assert_eq(r.bool_by("b"), true)
  assert_eq(r.int_by("i"), 42)
  assert_eq(r.int64_by("big"), 9000000000L)
  assert_eq(r.double_by("d"), 3.5)
  assert_eq(r.text_by("t"), "hi")
  assert_eq(r.blob_by("raw"), b"\xde\xad")
  assert_eq(r.is_null_by("n"), true)
}

///|
test "row: by-name integer/double accessors widen and narrow like positional" {
  let r : Row = { columns: ["a"], values: [Int(5)], }
  assert_eq(r.int64_by("a"), 5L) // Int widens to Int64
  assert_eq(r.double_by("a"), 5.0) // Int widens to Double
  let big : Row = { columns: ["a"], values: [Int64(7)], }
  assert_eq(big.int_by("a"), 7) // Int64 narrows to Int
  assert_eq(big.double_by("a"), 7.0) // Int64 widens to Double
}

///|
fn by_name_raises(kind : String, f : () -> Unit raise DbError) -> Bool {
  try {
    f()
    false
  } catch {
    TypeError(_) => kind == "type"
    QueryError(_) => kind == "query"
    _ => false
  }
}

///|
test "row: a by-name read of the wrong type raises TypeError" {
  let r = typed_row()
  assert_eq(by_name_raises("type", () => r.int_by("t") |> ignore), true)
  assert_eq(by_name_raises("type", () => r.text_by("i") |> ignore), true)
  assert_eq(by_name_raises("type", () => r.bool_by("d") |> ignore), true)
  assert_eq(by_name_raises("type", () => r.blob_by("i") |> ignore), true)
  assert_eq(by_name_raises("type", () => r.double_by("t") |> ignore), true)
  // A NULL column has no type, so a typed by-name read is a TypeError too.
  assert_eq(by_name_raises("type", () => r.int_by("n") |> ignore), true)
}

///|
test "row: a by-name read of an absent column raises QueryError" {
  let r = typed_row()
  assert_eq(by_name_raises("query", () => r.int_by("nope") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.text_by("gone") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.blob_by("x") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.is_null_by("x") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.bool_by("x") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.int64_by("x") |> ignore), true)
  assert_eq(by_name_raises("query", () => r.double_by("x") |> ignore), true)
}

///|
test "row: empty and boundary cells round-trip through the accessors" {
  let imax = 2147483647
  let imin = -2147483647 - 1
  let i64max = 9223372036854775807L
  let i64min = -9223372036854775807L - 1L
  let r : Row = {
    columns: ["empty_t", "empty_b", "imax", "imin", "i64max", "i64min"],
    values: [
      Text(""),
      Blob(b""),
      Int(imax),
      Int(imin),
      Int64(i64max),
      Int64(i64min),
    ],
  }
  assert_eq(r.text_by("empty_t"), "")
  assert_eq(r.blob_by("empty_b").length(), 0)
  assert_eq(r.int_by("imax"), imax)
  assert_eq(r.int_by("imin"), imin)
  assert_eq(r.int64_by("i64max"), i64max)
  assert_eq(r.int64_by("i64min"), i64min)
}

// --- DbError: every case renders and Shows the same ----------------------------

///|
test "db error: Show renders every case identically to to_string" {
  let cases : Array[DbError] = [
    ConnectError("refused"),
    QueryError("bad sql"),
    TypeError("not Int"),
    Closed,
  ]
  for e in cases {
    assert_eq("\{e}", e.to_string())
  }
  assert_eq("\{(ConnectError("refused") : DbError)}", "ConnectError: refused")
  assert_eq("\{(TypeError("not Int") : DbError)}", "TypeError: not Int")
  assert_eq("\{(Closed : DbError)}", "Closed: operation on a closed connection")
}

// --- MockDriver: the transaction edges the per-file test leaves out -------------

///|
fn mock_raises_closed(f : () -> Unit raise DbError) -> Bool {
  try {
    f()
    false
  } catch {
    Closed => true
    _ => false
  }
}

///|
test "mock driver: commit and rollback after close also raise Closed" {
  let db = MockDriver::new()
  db.begin()
  db.close()
  assert_eq(mock_raises_closed(() => db.commit()), true)
  assert_eq(mock_raises_closed(() => db.rollback()), true)
}

///|
test "mock driver: last_insert_id keeps climbing across a rolled-back span" {
  // Rollback restores the row snapshot but not the id counter — ids are never
  // reused, matching every real autoincrement.
  let db = MockDriver::new()
  let a = db.execute("INSERT", [Int(1)])
  db.begin()
  let b = db.execute("INSERT", [Int(2)])
  db.rollback()
  let c = db.execute("INSERT", [Int(3)])
  assert_eq(a.last_insert_id, 1L)
  assert_eq(b.last_insert_id, 2L)
  assert_eq(c.last_insert_id, 3L)
  assert_eq(db.row_count(), 2) // the rolled-back insert is gone
}
