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
```

## Injection safety

```moonbit
let evil = "'; DROP TABLE users; --"
let (sql, params) = @moonorm.select("users").eq("name", @moonorm.Text(evil)).build()
// sql    = "SELECT * FROM users WHERE name = ?"   ← the attack string is NOT in the SQL
// params = [Text("'; DROP TABLE users; --")]      ← it's a bound parameter
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating SQLAlchemy)

`select` / `insert` / `update` / `delete` with WHERE / ORDER BY / LIMIT / OFFSET are here. Next, feature-by-feature: joins, group_by / having, subqueries and CTEs; a unified async `Driver` trait with SQLite and Postgres backends and connection pooling; an explicit `Session` (add / get / commit / rollback); `#orm`-annotated models with `moonctl`-generated table metadata and Row↔struct mapping; relationships with explicit `session.load()` eager loading (the faithful equivalent of SQLAlchemy's transparent lazy-load, which MoonBit's lack of attribute interception makes explicit — as Diesel and GORM also do); and Alembic-style migrations.

## License

Apache-2.0.
