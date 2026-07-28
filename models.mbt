// The declarative model layer: typed columns, a Row<->record mapper, and
// foreign-key relationships with explicit eager loading. SQLAlchemy derives all of
// this from Python classes at runtime via attribute interception; MoonBit has no
// reflection and no attribute interception, so the mapping is declared explicitly —
// a `Model[T]` descriptor carries the columns plus the two mapping closures
// (Row -> record, record -> bound columns). That is the same faithful, explicit
// trade Diesel (`table!` + `Queryable`/`Insertable`) and GORM make, and it keeps
// the whole layer pure so it compiles on every backend; only the concrete driver
// is native-gated.

///|
/// A column's SQL storage type. These map onto SQLite's type affinities when a
/// `Model` renders `CREATE TABLE` DDL: `IntType`/`BoolType` -> INTEGER, `TextType`
/// -> TEXT, `RealType` -> REAL, `BlobType` -> BLOB. `BoolType` is a distinct
/// declared type so DDL reads intently, but binds and reads as an integer `0`/`1`.
pub(all) enum ColumnType {
  IntType
  TextType
  RealType
  BlobType
  BoolType
} derive(Eq)

///|
/// The SQLite declared type keyword for a `ColumnType`.
fn ColumnType::sql(self : ColumnType) -> String {
  match self {
    IntType => "INTEGER"
    BoolType => "INTEGER"
    TextType => "TEXT"
    RealType => "REAL"
    BlobType => "BLOB"
  }
}

///|
/// One declared column of a `Model`: its `name`, storage `col_type`, whether it is
/// the (or part of the) primary key, whether it accepts NULL, and an optional
/// foreign-key `references` target `(table, column)`. This is the explicit stand-in
/// for SQLAlchemy's `mapped_column(...)` — every fact that framework reads off the
/// annotated attribute is stated here as data.
pub(all) struct Column {
  name : String
  col_type : ColumnType
  primary_key : Bool
  nullable : Bool
  references : (String, String)?
}

///|
/// Declare a `Column`. `primary_key` and `references` default off; a primary-key
/// column is `NOT NULL` implicitly (SQLite treats INTEGER PRIMARY KEY as the
/// rowid), and `nullable` defaults to `true` for every other column, matching
/// SQLAlchemy's `nullable=True` default.
pub fn column(
  name : String,
  col_type : ColumnType,
  primary_key? : Bool = false,
  nullable? : Bool = true,
  references? : (String, String)? = None,
) -> Column {
  { name, col_type, primary_key, nullable, references }
}

///|
/// Render this column as a single `CREATE TABLE` column definition, e.g.
/// `"user_id INTEGER NOT NULL REFERENCES users(id)"`. A `PRIMARY KEY` column emits
/// that keyword; a non-nullable column emits `NOT NULL`; a `references` target
/// emits a `REFERENCES table(column)` clause. Column and table names are trusted
/// identifiers declared in code, never bound values.
pub fn Column::ddl(self : Column) -> String {
  let mut s = self.name + " " + self.col_type.sql()
  if self.primary_key {
    s = s + " PRIMARY KEY"
  } else if !self.nullable {
    s = s + " NOT NULL"
  }
  match self.references {
    Some((t, c)) => s = s + " REFERENCES " + t + "(" + c + ")"
    None => ()
  }
  s
}

///|
/// A declarative model: the mapping between a database table and a MoonBit record
/// type `T`. It bundles the `table` name, the ordered `columns`, and the two mapping
/// closures that MoonBit cannot synthesise for want of reflection:
/// `from_row` decodes a fetched `Row` into a `T`, and `to_columns` projects a `T`
/// back into the `(name, Value)` pairs an INSERT binds. Build one with `Model::new`.
///
/// This is the faithful explicit equivalent of a SQLAlchemy declarative class — the
/// columns are the `mapped_column`s, and the two closures are the automatic
/// attribute<->column mapping made visible. Being a plain value it stays pure and
/// compiles on every backend.
pub struct Model[T] {
  table : String
  columns : Array[Column]
  from_row : (@moondb.Row) -> T raise @moondb.DbError
  to_columns : (T) -> Array[(String, Value)]
}

///|
/// Define a `Model[T]`. `from_row` should read the record's fields off the
/// `@moondb.Row` (via `Row::text` / `Row::int` / `Row::by_name` …) — those accessors
/// raise `@moondb.DbError` on a type or index mismatch, so `from_row` raises too and
/// a decode bug surfaces at the call site. `to_columns` should list the column/value
/// pairs to persist (typically every column except an autoincrement primary key).
/// Write the closures in arrow form so the `raise` effect is inferred, e.g.
/// `(r) => \{ id: r.int(0), name: r.text(1) \}`.
pub fn[T] Model::new(
  table : String,
  columns : Array[Column],
  from_row : (@moondb.Row) -> T raise @moondb.DbError,
  to_columns : (T) -> Array[(String, Value)],
) -> Model[T] {
  { table, columns, from_row, to_columns }
}

///|
/// The declared column names, in order.
pub fn[T] Model::column_names(self : Model[T]) -> Array[String] {
  let names : Array[String] = []
  for c in self.columns {
    names.push(c.name)
  }
  names
}

///|
/// A `Select` over this model's table with every declared column projected
/// explicitly (so the projection order is fixed and known to `from_row`). Add
/// `where_` / `order_by` / `limit` to it as usual, then run it with
/// `Session::fetch_as` to get mapped records back.
pub fn[T] Model::select(self : Model[T]) -> Select {
  let s = select(self.table)
  for c in self.columns {
    s.cols.push(c.name)
  }
  s
}

///|
/// The `Table` descriptor for this model (name + column names), for interop with
/// the plain builder API.
pub fn[T] Model::table_descriptor(self : Model[T]) -> Table {
  { name: self.table, columns: self.column_names() }
}

///|
/// Render `CREATE TABLE` DDL for this model from its declared columns. With
/// `if_not_exists=true` the statement is idempotent (`CREATE TABLE IF NOT EXISTS`).
/// This is the explicit counterpart of SQLAlchemy's `metadata.create_all()`.
pub fn[T] Model::create_table_sql(
  self : Model[T],
  if_not_exists? : Bool = false,
) -> String {
  let head = if if_not_exists {
    "CREATE TABLE IF NOT EXISTS "
  } else {
    "CREATE TABLE "
  }
  let defs : Array[String] = []
  for c in self.columns {
    defs.push(c.ddl())
  }
  head + self.table + " (" + join(defs, ", ") + ")"
}

///|
/// Build an `Insert` that persists `record`, binding the pairs from `to_columns`.
/// Values travel as `?` placeholders exactly like the rest of the builder.
pub fn[T] Model::insert_of(self : Model[T], record : T) -> Insert {
  let ins = insert(self.table)
  for pair in (self.to_columns)(record) {
    ins.set(pair.0, pair.1) |> ignore
  }
  ins
}

///|
/// Decode a single fetched `Row` into a record via the model's `from_row`.
pub fn[T] Model::map_row(
  self : Model[T],
  row : @moondb.Row,
) -> T raise @moondb.DbError {
  (self.from_row)(row)
}

///|
/// Decode a whole result set into records, preserving row order.
pub fn[T] Model::map_rows(
  self : Model[T],
  rows : Array[@moondb.Row],
) -> Array[T] raise @moondb.DbError {
  let out : Array[T] = []
  for r in rows {
    out.push((self.from_row)(r))
  }
  out
}

///|
/// A foreign-key relationship from a source record `S` to a `target` model `T`,
/// resolved by matching `target.key_column` against a `Value` extracted from the
/// source. `to_many` records the cardinality (a 1:N parent->children link versus a
/// N:1 child->parent link) so callers know whether to expect many rows or one.
///
/// Because MoonBit has no attribute interception, touching `hero.team` cannot
/// silently emit a SELECT the way SQLAlchemy's lazy load does. The relationship is
/// therefore a first-class value and the load is explicit — `Session::load` /
/// `Session::load_one` — exactly the eager, explicit shape Diesel's `belonging_to`
/// / preload and GORM's `Preload` take.
pub struct Relation[S, T] {
  target : Model[T]
  key_column : String
  source_key : (S) -> Value
  to_many : Bool
}

///|
/// A 1:N relationship: `parent` -> its children in `target`, matched by the child's
/// `foreign_key` column equalling the parent key extracted by `parent_key`. Load it
/// with `Session::load`, which returns every matching child record.
pub fn[S, T] has_many(
  target : Model[T],
  foreign_key : String,
  parent_key : (S) -> Value,
) -> Relation[S, T] {
  { target, key_column: foreign_key, source_key: parent_key, to_many: true }
}

///|
/// A N:1 relationship: `child` -> its single parent in `target`, matched by the
/// parent's `target_key` column (usually its primary key) equalling the foreign
/// key extracted from the child by `child_key`. Load it with `Session::load_one`.
pub fn[S, T] belongs_to(
  target : Model[T],
  target_key : String,
  child_key : (S) -> Value,
) -> Relation[S, T] {
  { target, key_column: target_key, source_key: child_key, to_many: false }
}

///|
/// The `Select` that resolves this relationship for a given `source` record: the
/// target model's projection filtered to `key_column = ?`, with the source-derived
/// value bound (never spliced), so eager loading is injection-safe like every other
/// query. `Session::load` runs this and maps the rows.
pub fn[S, T] Relation::query(self : Relation[S, T], source : S) -> Select {
  self.target.select().where_(self.key_column, "=", (self.source_key)(source))
}
