<div align="center">

# moonorm

**An ORM / SQL toolkit for MoonBit — `← SQLAlchemy / SQLModel`.**

[![Check and Test](https://github.com/Lfan-ke/moonorm/actions/workflows/ci.yml/badge.svg)](https://github.com/Lfan-ke/moonorm/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonorm-brightgreen)](https://mooncakes.io/docs/Lfan-ke/moonorm)

</div>

`moonorm` is the MoonBit counterpart to SQLAlchemy. `v0` ships the heart of SQLAlchemy Core — a **parameterized, injection-safe query builder**. Values are never spliced into the SQL string; every bound value becomes a `?` placeholder plus an entry in a params list, so injection is impossible by construction.

## Quickstart

```moonbit
let (sql, params) = @moonorm.select("users")
  .column("id").column("name")
  .eq("age", @moonorm.Int(18))
  .where_("name", "LIKE", @moonorm.Text("bob%"))
  .order_by("name", @moonorm.Asc)
  .limit(10)
  .build()
// sql    = "SELECT id, name FROM users WHERE age = ? AND name LIKE ? ORDER BY name ASC LIMIT 10"
// params = [Int(18), Text("bob%")]

let (isql, ivals) = @moonorm.insert("users")
  .set("name", @moonorm.Text("bob")).set("age", @moonorm.Int(30)).build()
// "INSERT INTO users (name, age) VALUES (?, ?)"

@moonorm.update("users").set("age", @moonorm.Int(31)).where_("id", "=", @moonorm.Int(1)).build()
@moonorm.delete("users").where_("id", "=", @moonorm.Int(9)).build()

// JOIN + GROUP BY + HAVING, with aggregates and a Table descriptor:
let orders : @moonorm.Table = { name: "orders", columns: [] }
let (jsql, jparams) = orders.select()
  .raw("users.name").count()
  .join("users", "users.id = orders.user_id")
  .eq("orders.status", @moonorm.Text("paid"))
  .group_by("users.name")
  .having("COUNT(*)", ">", @moonorm.Int(3))
  .build()
// "SELECT users.name, COUNT(*) FROM orders JOIN users ON users.id = orders.user_id
//  WHERE orders.status = ? GROUP BY users.name HAVING COUNT(*) > ?"
// params = [Text("paid"), Int(3)]
```

## Running against a real database

The builder is only half the story — `moonorm` also **executes**. The `sqlite`
sub-package is a real native SQLite backend (built on the vendored SQLite
amalgamation, public domain) that implements the `Driver` trait, so a `Session`
runs your built statements against an actual database and hands back typed rows.

```moonbit
// native target only — the SQLite driver links the vendored amalgamation.
let conn = match @sqlite.SqliteConn::open(":memory:") {
  Ok(c) => c
  Err(e) => { println(e.to_string()); return }
}
let sess = @moonorm.Session::new(conn)
sess.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", []) |> ignore

// INSERT through the builder — values are bound, never spliced.
sess.add(@moonorm.insert("users").set("name", @moonorm.Text("alice")).set("age", @moonorm.Int(30))) |> ignore

// SELECT through the builder — real rows come back, typed.
let rows = match sess.fetch(
  @moonorm.select("users").column("name").column("age").where_("age", ">", @moonorm.Int(18)),
) {
  Ok(rs) => rs
  Err(e) => { println(e.to_string()); return }
}
rows[0].text(0)  // Some("alice")
rows[0].int(1)   // Some(30)
```

`Session` also has `modify` (UPDATE), `remove` (DELETE), `begin` / `commit` /
`rollback`, nested transactions via `savepoint` / `rollback_to` / `release`
(SQLAlchemy's `begin_nested`), and raw `execute` / `query`. Everything travels as
bound parameters, so the injection-safety guarantee reaches all the way to the wire.

## Models & relationships

A `Model[T]` is the explicit declarative mapping between a table and a MoonBit
record — the typed columns plus the two mapping closures MoonBit cannot synthesise
for want of reflection (`Row -> record`, `record -> bound columns`). From it you get
`CREATE TABLE` DDL, typed inserts, and eager foreign-key loading. Because MoonBit
has no attribute interception, `parent.children` cannot silently fire a SELECT the
way SQLAlchemy's lazy load does; the load is an explicit call — `session.load` /
`session.load_one` — exactly the shape Diesel's preload and GORM's `Preload` take.

```moonbit
// A parent model and a child model with a foreign key back to it.
let teams : @moonorm.Model[Team] = @moonorm.Model::new(
  "teams",
  [@moonorm.column("id", @moonorm.IntType, primary_key=true),
   @moonorm.column("name", @moonorm.TextType, nullable=false)],
  fn(r) { { id: r.int(0).unwrap(), name: r.text(1).unwrap() } },
  fn(t) { [("id", @moonorm.Int(t.id)), ("name", @moonorm.Text(t.name))] },
)
let heroes : @moonorm.Model[Hero] = @moonorm.Model::new(
  "heroes",
  [@moonorm.column("id", @moonorm.IntType, primary_key=true),
   @moonorm.column("name", @moonorm.TextType, nullable=false),
   @moonorm.column("team_id", @moonorm.IntType, references=Some(("teams", "id")))],
  fn(r) { { id: r.int(0).unwrap(), name: r.text(1).unwrap(), team_id: r.int(2).unwrap() } },
  fn(h) { [("id", @moonorm.Int(h.id)), ("name", @moonorm.Text(h.name)),
           ("team_id", @moonorm.Int(h.team_id))] },
)

sess.create_table(teams) |> ignore          // CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL)
sess.create_table(heroes) |> ignore
sess.insert_record(teams, { id: 1, name: "avengers" }) |> ignore
sess.insert_record(heroes, { id: 10, name: "iron-man", team_id: 1 }) |> ignore

// 1:N — a team's heroes, eager-loaded as mapped records.
let children = @moonorm.has_many(heroes, "team_id", fn(t : Team) { @moonorm.Int(t.id) })
let kids = sess.load({ id: 1, name: "avengers" }, children)   // Ok([Hero{...}, ...])

// N:1 — a hero's team.
let parent = @moonorm.belongs_to(teams, "id", fn(h : Hero) { @moonorm.Int(h.team_id) })
let team = sess.load_one({ id: 10, name: "iron-man", team_id: 1 }, parent)  // Ok(Some(Team{...}))
```

The relationship's match value is bound, never spliced, so eager loading is
injection-safe like every other query. The integration tests open a real SQLite
database, create parent/child tables, insert linked rows, then `load` a parent's
children and a child's parent and assert on the mapped records — mutation-verified
(flipping the join predicate turns them red).

### Design & boundaries (honest)

- **Explicit, not magic.** SQLAlchemy issues SQL implicitly when you touch a
  mapped attribute; MoonBit has no attribute interception, so every statement is
  issued explicitly via `Session` — the same faithful trade Diesel and GORM make.
- **The driver is native-only.** The SQLite backend is a C FFI over the vendored
  amalgamation, so it links and runs on the `native` target. The pure query
  builder and the `Session` / `Driver` / `Row` layer compile on **every** backend
  (`wasm` / `wasm-gc` / `js` / `native`); only the concrete SQLite `Driver` is
  gated to `native`. A Postgres wire-protocol backend and a JS `node:sqlite`
  backend are next on the roadmap.
- **Real, verified execution.** The integration tests open an actual SQLite
  database and assert on rows read back; they are mutation-verified (neutering the
  C step/bind/column path turns them red), so "it runs" is proven, not claimed.

## Injection safety

```moonbit
let evil = "'; DROP TABLE users; --"
let (sql, params) = @moonorm.select("users").eq("name", @moonorm.Text(evil)).build()
// sql    = "SELECT * FROM users WHERE name = ?"   ← the attack string is NOT in the SQL
// params = [Text("'; DROP TABLE users; --")]      ← it's a bound parameter
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating SQLAlchemy)

`select` / `insert` / `update` / `delete` with WHERE / ORDER BY / LIMIT / OFFSET, inner/left `JOIN`, `GROUP BY` / `HAVING`, aggregate columns (`count()` / `raw()`), and a `Table` descriptor are all here — and now they **execute**: a `Driver` trait with a real native **SQLite** backend and an explicit `Session` (`add` / `fetch` / `modify` / `remove` / `commit` / `rollback`) that runs built statements against a live database. Next, feature-by-feature: a Postgres wire-protocol backend and connection pooling; subqueries and CTEs; `#orm`-annotated models with `moonctl`-generated table metadata and Row↔struct mapping; relationships with explicit `session.load()` eager loading (the faithful equivalent of SQLAlchemy's transparent lazy-load, which MoonBit's lack of attribute interception makes explicit — as Diesel and GORM also do); and Alembic-style migrations.

## License

Apache-2.0.
