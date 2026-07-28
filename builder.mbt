///|
/// A bound SQL value. Values are always carried out-of-band as parameters, never
/// interpolated into the SQL string — that is what makes the builder injection-safe.
pub(all) enum Value {
  Int(Int)
  Text(String)
  Bool(Bool)
  Null
} derive(Eq)

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
  conds : Array[Cond]
  orders : Array[(String, Order)]
  mut limit_ : Int?
  mut offset_ : Int?
}

///|
/// Start a SELECT over `table`.
pub fn select(table : String) -> Select {
  { table, cols: [], conds: [], orders: [], limit_: None, offset_: None }
}

///|
/// Add a projected column (no columns selects `*`).
pub fn Select::column(self : Select, col : String) -> Select {
  self.cols.push(col)
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
  if self.conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    sql = sql + " WHERE " + join(cparts, " AND ")
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
