# Examples

Runnable `main` packages that use the public `@moonorm` API. Each folder builds a
statement, prints the SQL and its bound params, and — where it helps — runs it.

```bash
moon run examples/00-recursive-cte
```

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`recursive-cte`](00-recursive-cte/) | A `Model` over a self-referential table, a filtered `SELECT`, and a `WITH RECURSIVE` subtree walk — then the same builders driving a `Session` | `Model::new`, `column`, `Model::select`, `select`, `where_`, `order_by`, `limit`, `with_recursive`, `build`, `Session::new`, `insert_record`, `all` |

Values never enter the SQL string: every bound value becomes a `?` placeholder and
one entry in the params list, in text order. The recursive walk composes an anchor
term and a step term that refers back to the CTE name, so `with_recursive` renders
`WITH RECURSIVE subtree AS (<anchor> UNION ALL <step>)`.

The `Session` round trip runs against `@moondb.MockDriver`, a dependency-free echo
store that compiles on every backend — no database, no native driver. For real SQL,
point a `Session` at a concrete `@moondb.Driver` (the native SQLite driver lives in
[`moon-sqlite`](https://github.com/Lfan-ke/moon-sqlite)); the builders are identical.
