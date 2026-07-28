///|
/// The bound-value type is moondb's dialect-neutral [`@moondb.Value`], re-exported
/// here so the builder's public surface reads as `Value` (and its constructors —
/// `Int`, `Text`, `Null`, …) stay unqualified) while the actual type is the one every
/// moondb driver speaks. Values are always carried out-of-band as parameters, never
/// interpolated into the SQL string — that is what makes the builder injection-safe.
pub using @moondb {type Value}

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
/// A `col IN (subquery)` / `col NOT IN (subquery)` predicate: the subquery is a
/// full `Select`, whose bound parameters splice in at the point the predicate is
/// rendered. Keeping subquery predicates separate from the scalar `conds` lets the
/// builder concatenate the two params streams in the exact order the SQL text emits
/// them (scalar predicates first, then subqueries), so binding stays index-aligned.
struct SubCond {
  col : String
  op : String
  sub : Select
}

///|
/// A common table expression: `name AS (subquery)`. CTEs render in a single leading
/// `WITH` clause and their bound parameters come first in the final params list,
/// matching their leading position in the SQL text.
struct Cte {
  name : String
  sub : Select
}

///|
/// A SELECT statement builder.
pub struct Select {
  table : String
  ctes : Array[Cte]
  cols : Array[String]
  joins : Array[JoinClause]
  conds : Array[Cond]
  sub_conds : Array[SubCond]
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
    ctes: [],
    cols: [],
    joins: [],
    conds: [],
    sub_conds: [],
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
/// Attach a common table expression: `WITH name AS (sub)`. Repeatable — several
/// CTEs render comma-separated in one leading `WITH`. The subquery is parameterised
/// like any other statement; its bound values lead the final params list because
/// the `WITH` clause leads the SQL text. `name` is a trusted identifier declared in
/// code, never a bound value.
pub fn Select::with_cte(self : Select, name : String, sub : Select) -> Select {
  self.ctes.push({ name, sub })
  self
}

///|
/// Add a `col IN (subquery)` predicate (ANDed with the rest). The subquery's bound
/// values splice in at the predicate's position, so a correlated or filtering
/// subquery stays injection-safe exactly like a scalar `where_`.
pub fn Select::where_in(self : Select, col : String, sub : Select) -> Select {
  self.sub_conds.push({ col, op: "IN", sub })
  self
}

///|
/// Add a `col NOT IN (subquery)` predicate (ANDed with the rest). See `where_in`.
pub fn Select::where_not_in(
  self : Select,
  col : String,
  sub : Select,
) -> Select {
  self.sub_conds.push({ col, op: "NOT IN", sub })
  self
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
/// Render to `(sql, params)`, with `?` placeholders for every bound value. Bound
/// values appear in the params list in the same left-to-right order they occur in
/// the SQL text: CTE subqueries first (the leading `WITH`), then the `WHERE` scalar
/// predicates, then the `WHERE` subquery predicates, then `HAVING`.
pub fn Select::build(self : Select) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let mut sql = ""
  if self.ctes.length() > 0 {
    let cte_parts : Array[String] = []
    for cte in self.ctes {
      let (sub_sql, sub_params) = cte.sub.build()
      cte_parts.push(cte.name + " AS (" + sub_sql + ")")
      for p in sub_params {
        params.push(p)
      }
    }
    sql = "WITH " + join(cte_parts, ", ") + " "
  }
  sql = sql +
    "SELECT " +
    (if self.cols.length() == 0 { "*" } else { join(self.cols, ", ") }) +
    " FROM " +
    self.table
  for j in self.joins {
    sql = sql + " " + j.kind + " " + j.table + " ON " + j.on
  }
  if self.conds.length() > 0 || self.sub_conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    for sc in self.sub_conds {
      let (sub_sql, sub_params) = sc.sub.build()
      cparts.push(sc.col + " " + sc.op + " (" + sub_sql + ")")
      for p in sub_params {
        params.push(p)
      }
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
