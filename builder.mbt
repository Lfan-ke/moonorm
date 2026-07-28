///|
/// A bound SQL value. Values are always carried out-of-band as parameters, never
/// interpolated into the SQL string — that is what makes the builder injection-safe.
///
/// The variants mirror SQLite's dynamic storage classes: `Int`/`Int64` map to
/// INTEGER, `Double` to REAL, `Text` to TEXT, `Bool` binds as `0`/`1`, and `Null`
/// to NULL. Rows read back from a driver are decoded into the same type.
pub(all) enum Value {
  Int(Int)
  Int64(Int64)
  Text(String)
  Double(Double)
  Bool(Bool)
  Null
} derive(Eq, Debug)

///|
/// Sort direction for an ORDER BY term.
pub(all) enum Order {
  Asc
  Desc
} derive(Eq)

///|
fn order_sql(o : Order) -> String {
  match o {
    Asc => "ASC"
    Desc => "DESC"
  }
}

///|
struct Cond {
  col : String
  op : String
  val : Value
}

///|
/// A single JOIN clause: its keyword (`JOIN` / `LEFT JOIN`), the joined table,
/// and the raw `ON` predicate (an identifier-level expression, never a bound value).
struct JoinClause {
  kind : String
  table : String
  on : String
}

///|
fn join(parts : Array[String], sep : String) -> String {
  let mut out = ""
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      out = out + sep
    }
    out = out + parts[i]
  }
  out
}

// ---- SELECT ----

///|
/// A SELECT statement builder.
pub struct Select {
  table : String
  cols : Array[String]
  joins : Array[JoinClause]
  conds : Array[Cond]
  groups : Array[String]
  havings : Array[Cond]
  orders : Array[(String, Order)]
  mut limit_ : Int?
  mut offset_ : Int?
}

///|
/// Start a SELECT over `table`.
pub fn select(table : String) -> Select {
  {
    table,
    cols: [],
    joins: [],
    conds: [],
    groups: [],
    havings: [],
    orders: [],
    limit_: None,
    offset_: None,
  }
}

///|
/// Add a projected column (no columns selects `*`).
pub fn Select::column(self : Select, col : String) -> Select {
  self.cols.push(col)
  self
}

///|
/// Add a raw column expression (e.g. an aggregate like `"SUM(price)"` or a
/// qualified `"users.id"`). Identical machinery to `column`; named for intent so
/// call sites read as "this is an expression, not a plain column name".
pub fn Select::raw(self : Select, expr : String) -> Select {
  self.cols.push(expr)
  self
}

///|
/// Project `COUNT(*)` — the most common aggregate. Sugar for `raw("COUNT(*)")`.
pub fn Select::count(self : Select) -> Select {
  self.cols.push("COUNT(*)")
  self
}

///|
/// Add an inner `JOIN table ON <on>`. The `on` predicate is rendered verbatim
/// (it references columns, not bound values), so pass only trusted identifiers.
pub fn Select::join(self : Select, table : String, on : String) -> Select {
  self.joins.push({ kind: "JOIN", table, on })
  self
}

///|
/// Add a `LEFT JOIN table ON <on>`. See `join` for the `on` contract.
pub fn Select::left_join(self : Select, table : String, on : String) -> Select {
  self.joins.push({ kind: "LEFT JOIN", table, on })
  self
}

///|
/// Add a `GROUP BY` column (repeatable; columns are emitted in call order).
pub fn Select::group_by(self : Select, col : String) -> Select {
  self.groups.push(col)
  self
}

///|
/// Add a `col op ?` predicate to the `HAVING` clause (ANDed with the rest). The
/// value is bound as a `?` placeholder exactly like `where_`, so aggregate
/// filters stay injection-safe.
pub fn Select::having(
  self : Select,
  col : String,
  op : String,
  val : Value,
) -> Select {
  self.havings.push({ col, op, val })
  self
}

///|
/// Add a `col op ?` predicate (ANDed with the rest).
pub fn Select::where_(
  self : Select,
  col : String,
  op : String,
  val : Value,
) -> Select {
  self.conds.push({ col, op, val })
  self
}

///|
/// Shorthand for `where_(col, "=", val)`.
pub fn Select::eq(self : Select, col : String, val : Value) -> Select {
  self.where_(col, "=", val)
}

///|
pub fn Select::order_by(self : Select, col : String, ord : Order) -> Select {
  self.orders.push((col, ord))
  self
}

///|
pub fn Select::limit(self : Select, n : Int) -> Select {
  self.limit_ = Some(n)
  self
}

///|
pub fn Select::offset(self : Select, n : Int) -> Select {
  self.offset_ = Some(n)
  self
}

///|
/// Render to `(sql, params)`, with `?` placeholders for every bound value.
pub fn Select::build(self : Select) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let mut sql = "SELECT " +
    (if self.cols.length() == 0 { "*" } else { join(self.cols, ", ") }) +
    " FROM " +
    self.table
  for j in self.joins {
    sql = sql + " " + j.kind + " " + j.table + " ON " + j.on
  }
  if self.conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    sql = sql + " WHERE " + join(cparts, " AND ")
  }
  if self.groups.length() > 0 {
    sql = sql + " GROUP BY " + join(self.groups, ", ")
  }
  if self.havings.length() > 0 {
    let hparts : Array[String] = []
    for h in self.havings {
      hparts.push(h.col + " " + h.op + " ?")
      params.push(h.val)
    }
    sql = sql + " HAVING " + join(hparts, " AND ")
  }
  if self.orders.length() > 0 {
    let oparts : Array[String] = []
    for o in self.orders {
      oparts.push(o.0 + " " + order_sql(o.1))
    }
    sql = sql + " ORDER BY " + join(oparts, ", ")
  }
  match self.limit_ {
    Some(n) => sql = sql + " LIMIT " + n.to_string()
    None => ()
  }
  match self.offset_ {
    Some(n) => sql = sql + " OFFSET " + n.to_string()
    None => ()
  }
  (sql, params)
}

///|
/// A lightweight table descriptor: a table `name` plus its known `columns`. It is
/// the hand-written stand-in for SQLAlchemy's `Table(...)` metadata object —
/// MoonBit has no reflection, so the schema is declared explicitly rather than
/// introspected. `select()` turns it into a `Select` with every column projected.
pub(all) struct Table {
  name : String
  columns : Array[String]
}

///|
/// Start a SELECT over this table with all of its declared `columns` projected
/// (an empty `columns` yields `SELECT *`, matching `select(name)`).
pub fn Table::select(self : Table) -> Select {
  let s = select(self.name)
  for c in self.columns {
    s.cols.push(c)
  }
  s
}

// ---- INSERT ----

///|
/// An INSERT statement builder.
pub struct Insert {
  table : String
  cols : Array[String]
  vals : Array[Value]
}

///|
pub fn insert(table : String) -> Insert {
  { table, cols: [], vals: [] }
}

///|
/// Set a column to a value.
pub fn Insert::set(self : Insert, col : String, val : Value) -> Insert {
  self.cols.push(col)
  self.vals.push(val)
  self
}

///|
pub fn Insert::build(self : Insert) -> (String, Array[Value]) {
  let placeholders : Array[String] = []
  for _v in self.vals {
    placeholders.push("?")
  }
  let sql = "INSERT INTO " +
    self.table +
    " (" +
    join(self.cols, ", ") +
    ") VALUES (" +
    join(placeholders, ", ") +
    ")"
  (sql, self.vals)
}

// ---- UPDATE ----

///|
/// An UPDATE statement builder.
pub struct Update {
  table : String
  cols : Array[String]
  vals : Array[Value]
  conds : Array[Cond]
}

///|
pub fn update(table : String) -> Update {
  { table, cols: [], vals: [], conds: [] }
}

///|
pub fn Update::set(self : Update, col : String, val : Value) -> Update {
  self.cols.push(col)
  self.vals.push(val)
  self
}

///|
pub fn Update::where_(
  self : Update,
  col : String,
  op : String,
  val : Value,
) -> Update {
  self.conds.push({ col, op, val })
  self
}

///|
pub fn Update::build(self : Update) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let setparts : Array[String] = []
  for i = 0; i < self.cols.length(); i = i + 1 {
    setparts.push(self.cols[i] + " = ?")
    params.push(self.vals[i])
  }
  let mut sql = "UPDATE " + self.table + " SET " + join(setparts, ", ")
  if self.conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    sql = sql + " WHERE " + join(cparts, " AND ")
  }
  (sql, params)
}

// ---- DELETE ----

///|
/// A DELETE statement builder.
pub struct Delete {
  table : String
  conds : Array[Cond]
}

///|
pub fn delete(table : String) -> Delete {
  { table, conds: [] }
}

///|
pub fn Delete::where_(
  self : Delete,
  col : String,
  op : String,
  val : Value,
) -> Delete {
  self.conds.push({ col, op, val })
  self
}

///|
pub fn Delete::build(self : Delete) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let mut sql = "DELETE FROM " + self.table
  if self.conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    sql = sql + " WHERE " + join(cparts, " AND ")
  }
  (sql, params)
}
