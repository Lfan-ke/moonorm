// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "value kind names every variant" {
  assert_eq(Value::Null.kind(), "Null")
  assert_eq(Value::Bool(true).kind(), "Bool")
  assert_eq(Value::Int(1).kind(), "Int")
  assert_eq(Value::Int64(1).kind(), "Int64")
  assert_eq(Value::Double(1.0).kind(), "Double")
  assert_eq(Value::Text("x").kind(), "Text")
  assert_eq(Value::Blob(b"\x00").kind(), "Blob")
}

///|
test "value is_null only for Null" {
  assert_eq(Value::Null.is_null(), true)
  assert_eq(Value::Int(0).is_null(), false)
  assert_eq(Value::Text("").is_null(), false)
}

///|
test "value equality is structural" {
  assert_eq(Value::Int(7) == Value::Int(7), true)
  assert_eq(Value::Int(7) == Value::Int64(7), false)
  assert_eq(Value::Text("a") == Value::Text("a"), true)
  assert_eq(Value::Blob(b"ab") == Value::Blob(b"ab"), true)
  assert_eq(Value::Null == Value::Null, true)
}

///|
test "value show is legible and hides blob bytes" {
  assert_eq("\{Value::Int(42)}", "Int(42)")
  assert_eq("\{Value::Text("hi")}", "Text(\"hi\")")
  assert_eq("\{Value::Null}", "Null")
  assert_eq("\{Value::Blob(b"\x00\x01\x02")}", "Blob(3 bytes)")
}
