///|
test "diff_schema reports added, removed, and type-changed columns" {
  let declared = [
    column("id", IntType, primary_key=true),
    column("name", TextType),
    column("age", IntType),
  ]
  let reflected = [
    column("id", IntType, primary_key=true),
    column("name", TextType),
    column("email", TextType),
  ]
  // age is in the model only (Added); email only in the db (Removed); id/name match.
  let d = diff_schema(declared, reflected)
  assert_eq(d.length(), 2)
  assert_eq(d[0] == Added(name="age", col_type=IntType), true)
  assert_eq(d[1] == Removed("email"), true)
}

///|
test "diff_schema flags a changed column type" {
  let d = diff_schema([column("score", IntType)], [column("score", RealType)])
  assert_eq(d.length(), 1)
  assert_eq(d[0] == TypeChanged(name="score", from=RealType, to=IntType), true)
}

///|
test "diff_schema is empty when the schema matches" {
  let cols = [column("id", IntType, primary_key=true), column("v", TextType)]
  assert_eq(diff_schema(cols, cols).length(), 0)
}
