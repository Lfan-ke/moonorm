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
/// The SQL dialect a statement renders for. Most of the builder is dialect-neutral
/// — it emits `?` placeholders and standard clauses that every backend accepts —
/// but a few constructs genuinely differ: upsert is `ON CONFLICT ... DO UPDATE` on
/// SQLite and PostgreSQL versus `ON DUPLICATE KEY UPDATE` on MySQL, and `RETURNING`
/// exists on SQLite and PostgreSQL but not MySQL. `build_for` takes a `Dialect` so
/// those render correctly; the no-argument `build` renders the SQLite/PostgreSQL
/// form, which is also what the `?`-placeholder default targets.
pub(all) enum Dialect {
  Sqlite
  Postgres
  Mysql
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
/// A `col IN (?, ?, …)` / `col NOT IN (?, …)` predicate over an explicit value list
/// (as opposed to `SubCond`, whose right-hand side is a subquery). Each value binds
/// as its own placeholder, so a set-membership filter — the workhorse of an
/// N+1-avoiding batch load, `WHERE fk IN (all the parent keys)` — stays fully
/// parameterised.
struct InCond {
  col : String
  negated : Bool
  vals : Array[Value]
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
  in_conds : Array[InCond]
  sub_conds : Array[SubCond]
  groups : Array[String]
  havings : Array[Cond]
  orders : Array[(String, Order)]
  // Set operations chained onto this query: (keyword, operand). The compound's
  // ORDER BY / LIMIT come from this outer `Select`, applying to the whole result.
  set_ops : Array[(String, Select)]
  mut distinct_ : Bool
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
    in_conds: [],
    sub_conds: [],
    groups: [],
    havings: [],
    orders: [],
    set_ops: [],
    distinct_: false,
    limit_: None,
    offset_: None,
  }
}

///|
/// Deduplicate the result set: `SELECT DISTINCT`. Applies to this query's own
/// projection (each operand of a set operation carries its own DISTINCT).
pub fn Select::distinct(self : Select) -> Select {
  self.distinct_ = true
  self
}

///|
/// `UNION` this query with `other` — the combined rows with duplicates removed.
pub fn Select::union(self : Select, other : Select) -> Select {
  self.set_ops.push(("UNION", other))
  self
}

///|
/// `UNION ALL` — the combined rows keeping duplicates.
pub fn Select::union_all(self : Select, other : Select) -> Select {
  self.set_ops.push(("UNION ALL", other))
  self
}

///|
/// `INTERSECT` — rows present in both queries.
pub fn Select::intersect(self : Select, other : Select) -> Select {
  self.set_ops.push(("INTERSECT", other))
  self
}

///|
/// `EXCEPT` — rows in this query but not in `other` (SQL's set difference).
pub fn Select::except_(self : Select, other : Select) -> Select {
  self.set_ops.push(("EXCEPT", other))
  self
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
/// Project a window function: `<expr> OVER (PARTITION BY … ORDER BY …)`, optionally
/// aliased. Window functions compute over a frame of rows without collapsing them
/// (`ROW_NUMBER()`, `RANK()`, a running `SUM(x)`), so this adds one more projected
/// column rather than grouping. `expr` is the function call (`"ROW_NUMBER()"`,
/// `"SUM(amount)"`), `partition_by` splits the rows into independent windows, and
/// `order_by` ranks within each. All three are identifier-level SQL (they name
/// columns and functions, never bound values), so they render verbatim like `raw`
/// and carry no parameters. An empty `partition_by` and `order_by` yields the whole
/// result as one unordered window, `<expr> OVER ()`.
pub fn Select::window(
  self : Select,
  expr : String,
  partition_by? : Array[String] = [],
  order_by? : Array[(String, Order)] = [],
  as_? : String = "",
) -> Select {
  let inner : Array[String] = []
  if partition_by.length() > 0 {
    inner.push("PARTITION BY " + join(partition_by, ", "))
  }
  if order_by.length() > 0 {
    let oparts : Array[String] = []
    for o in order_by {
      oparts.push(o.0 + " " + order_sql(o.1))
    }
    inner.push("ORDER BY " + join(oparts, ", "))
  }
  let over = expr + " OVER (" + join(inner, " ") + ")"
  self.cols.push(if as_ == "" { over } else { over + " AS " + as_ })
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
/// Add a `col IN (?, ?, …)` predicate over an explicit list of values (ANDed with
/// the rest). Every value binds as its own placeholder, never spliced — this is the
/// set-membership filter a batch load issues to fetch the related rows of many
/// parents in one round trip (`WHERE fk IN (key1, key2, …)`) instead of one query
/// per parent. An empty `vals` renders `col IN (NULL)`, which matches nothing (the
/// SQL-correct reading of "in the empty set"); callers with no keys should skip the
/// query outright.
pub fn Select::where_in_values(
  self : Select,
  col : String,
  vals : Array[Value],
) -> Select {
  self.in_conds.push({ col, negated: false, vals })
  self
}

///|
/// Add a `col NOT IN (?, ?, …)` predicate over an explicit list of values (ANDed
/// with the rest). See `where_in_values`; an empty `vals` renders `col NOT IN
/// (NULL)`.
pub fn Select::where_not_in_values(
  self : Select,
  col : String,
  vals : Array[Value],
) -> Select {
  self.in_conds.push({ col, negated: true, vals })
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
/// predicates, then the `WHERE` `IN (values)` predicates, then the `WHERE` subquery
/// predicates, then `HAVING`.
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
    (if self.distinct_ { "DISTINCT " } else { "" }) +
    (if self.cols.length() == 0 { "*" } else { join(self.cols, ", ") }) +
    " FROM " +
    self.table
  for j in self.joins {
    sql = sql + " " + j.kind + " " + j.table + " ON " + j.on
  }
  if self.conds.length() > 0 ||
    self.in_conds.length() > 0 ||
    self.sub_conds.length() > 0 {
    let cparts : Array[String] = []
    for c in self.conds {
      cparts.push(c.col + " " + c.op + " ?")
      params.push(c.val)
    }
    for ic in self.in_conds {
      let placeholders : Array[String] = []
      if ic.vals.length() == 0 {
        placeholders.push("NULL")
      } else {
        for v in ic.vals {
          placeholders.push("?")
          params.push(v)
        }
      }
      let op = if ic.negated { "NOT IN" } else { "IN" }
      cparts.push(ic.col + " " + op + " (" + join(placeholders, ", ") + ")")
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
  // Set operations chain after this query's core; a trailing ORDER BY / LIMIT then
  // applies to the whole compound (SQL binds them to the last query otherwise).
  for so in self.set_ops {
    let (op, other) = so
    let (sub_sql, sub_params) = other.build()
    sql = sql + " " + op + " " + sub_sql
    for p in sub_params {
      params.push(p)
    }
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
/// The right-hand side of one `DO UPDATE` assignment in an upsert. `Bound` sets the
/// column to a bound value (`col = ?`), just like a normal update. `Excluded` sets
/// it to the value the conflicting `INSERT` tried to write — `excluded.col` on
/// SQLite/PostgreSQL, `VALUES(col)` on MySQL — which is how "insert or overwrite
/// with the new row" is spelled.
priv enum ConflictValue {
  Bound(Value)
  Excluded
}

///|
priv struct ConflictAssign {
  col : String
  value : ConflictValue
}

///|
/// The `ON CONFLICT` / `ON DUPLICATE KEY` clause of an upsert: the conflict-target
/// columns (the unique key that may collide — used by SQLite/PostgreSQL, implicit on
/// MySQL), the `DO UPDATE` assignments, and whether the intent is `DO NOTHING`.
struct Conflict {
  targets : Array[String]
  assigns : Array[ConflictAssign]
  mut do_nothing : Bool
}

///|
/// An INSERT statement builder, with optional upsert (`ON CONFLICT`) and
/// `RETURNING` support.
pub struct Insert {
  table : String
  cols : Array[String]
  vals : Array[Value]
  mut conflict : Conflict?
  returning : Array[String]
}

///|
pub fn insert(table : String) -> Insert {
  { table, cols: [], vals: [], conflict: None, returning: [] }
}

///|
/// Set a column to a value.
pub fn Insert::set(self : Insert, col : String, val : Value) -> Insert {
  self.cols.push(col)
  self.vals.push(val)
  self
}

///|
/// Ensure a `Conflict` exists, creating an empty one (no targets, no assigns) if
/// this is the first upsert call.
fn Insert::ensure_conflict(self : Insert) -> Conflict {
  match self.conflict {
    Some(c) => c
    None => {
      let c = { targets: [], assigns: [], do_nothing: false }
      self.conflict = Some(c)
      c
    }
  }
}

///|
/// Turn this INSERT into an upsert keyed on `targets` — the columns of the unique
/// index that may collide (SQLAlchemy's `index_elements`). Chain `do_update` /
/// `do_update_excluded` to say what to change on a collision, or leave it and call
/// `do_nothing`. SQLite and PostgreSQL name the conflict target explicitly;
/// `build_for(Mysql)` ignores it (MySQL infers the key), so pass it regardless and
/// the right dialect uses it.
pub fn Insert::on_conflict(self : Insert, targets : Array[String]) -> Insert {
  let c = self.ensure_conflict()
  for t in targets {
    c.targets.push(t)
  }
  self
}

///|
/// On a conflict, set `col` to a bound value (`col = ?`). The value binds as a
/// parameter after the inserted values, so an upsert stays injection-safe.
pub fn Insert::do_update(self : Insert, col : String, val : Value) -> Insert {
  let c = self.ensure_conflict()
  c.assigns.push({ col, value: Bound(val) })
  self
}

///|
/// On a conflict, set `col` to the value the failed insert tried to write
/// (`excluded.col` on SQLite/PostgreSQL, `VALUES(col)` on MySQL). This is the
/// "overwrite with the incoming row" upsert.
pub fn Insert::do_update_excluded(self : Insert, col : String) -> Insert {
  let c = self.ensure_conflict()
  c.assigns.push({ col, value: Excluded })
  self
}

///|
/// On a conflict, keep the existing row and change nothing (`ON CONFLICT DO
/// NOTHING`). MySQL has no such form, so `build_for(Mysql)` renders a no-op
/// self-assignment instead.
pub fn Insert::do_nothing(self : Insert) -> Insert {
  self.ensure_conflict().do_nothing = true
  self
}

///|
/// Return `col` from each inserted (or upserted) row. On SQLite and PostgreSQL this
/// appends `RETURNING`, so a caller reads the server-assigned id or a
/// default/trigger-computed value back in the same round trip instead of a second
/// SELECT. Repeatable. `build_for(Mysql)` drops it — MySQL has no `RETURNING`.
pub fn Insert::returning(self : Insert, col : String) -> Insert {
  self.returning.push(col)
  self
}

///|
/// Return every column of each inserted row (`RETURNING *`). See `returning`.
pub fn Insert::returning_all(self : Insert) -> Insert {
  self.returning.push("*")
  self
}

///|
/// Render to `(sql, params)` for the SQLite/PostgreSQL dialect. Equivalent to
/// `build_for(Sqlite)`; kept as the no-argument default because plain inserts and
/// the `?`-placeholder convention target this form.
pub fn Insert::build(self : Insert) -> (String, Array[Value]) {
  self.build_for(Sqlite)
}

///|
/// Render to `(sql, params)` for `dialect`, with `?` placeholders for every bound
/// value. Bound values appear in params in SQL-text order: the inserted `VALUES`
/// first, then any `DO UPDATE SET col = ?` values. Upsert renders as `ON CONFLICT`
/// on SQLite/PostgreSQL and `ON DUPLICATE KEY UPDATE` on MySQL; `RETURNING` is
/// emitted on SQLite/PostgreSQL and omitted on MySQL.
pub fn Insert::build_for(
  self : Insert,
  dialect : Dialect,
) -> (String, Array[Value]) {
  let params : Array[Value] = []
  let placeholders : Array[String] = []
  for v in self.vals {
    placeholders.push("?")
    params.push(v)
  }
  let mut sql = "INSERT INTO " +
    self.table +
    " (" +
    join(self.cols, ", ") +
    ") VALUES (" +
    join(placeholders, ", ") +
    ")"
  match self.conflict {
    Some(c) => sql = sql + render_conflict(c, dialect, self.cols, params)
    None => ()
  }
  if self.returning.length() > 0 && dialect != Mysql {
    sql = sql + " RETURNING " + join(self.returning, ", ")
  }
  (sql, params)
}

///|
/// Render an upsert clause for `dialect`, pushing any bound update values onto
/// `params` (they follow the inserted values in SQL-text order). `insert_cols` is
/// the inserted column list, used only to pick a valid no-op assignment for MySQL's
/// `DO NOTHING`, which has no native spelling.
fn render_conflict(
  c : Conflict,
  dialect : Dialect,
  insert_cols : Array[String],
  params : Array[Value],
) -> String {
  match dialect {
    Mysql => {
      let sets : Array[String] = []
      if c.do_nothing && c.assigns.length() == 0 {
        // MySQL cannot skip the update list; assign a key column to itself.
        let key = if c.targets.length() > 0 {
          c.targets[0]
        } else if insert_cols.length() > 0 {
          insert_cols[0]
        } else {
          "1"
        }
        sets.push(key + " = " + key)
      } else {
        for a in c.assigns {
          match a.value {
            Bound(v) => {
              sets.push(a.col + " = ?")
              params.push(v)
            }
            Excluded => sets.push(a.col + " = VALUES(" + a.col + ")")
          }
        }
      }
      " ON DUPLICATE KEY UPDATE " + join(sets, ", ")
    }
    _ => {
      let target = if c.targets.length() > 0 {
        " (" + join(c.targets, ", ") + ")"
      } else {
        ""
      }
      if c.do_nothing && c.assigns.length() == 0 {
        " ON CONFLICT" + target + " DO NOTHING"
      } else {
        let sets : Array[String] = []
        for a in c.assigns {
          match a.value {
            Bound(v) => {
              sets.push(a.col + " = ?")
              params.push(v)
            }
            Excluded => sets.push(a.col + " = excluded." + a.col)
          }
        }
        " ON CONFLICT" + target + " DO UPDATE SET " + join(sets, ", ")
      }
    }
  }
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
