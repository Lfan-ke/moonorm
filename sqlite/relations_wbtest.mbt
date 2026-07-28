// Real end-to-end integration tests for the model + relationship layer against an
// actual SQLite database: declare parent/child models, create their tables, insert
// linked rows, then eagerly `load` a parent's children (1:N) and a child's parent
// (N:1) and assert on the *mapped records* — not raw rows. If the join/load does not
// truly filter and map, these assertions fail (mutation-verified: flipping the
// relationship predicate turns them red).

///|
struct Team {
  id : Int
  name : String
} derive(Eq, Debug)

///|
struct Hero {
  id : Int
  name : String
  team_id : Int
}

///|
fn req_int(o : Int?) -> Int {
  match o {
    Some(v) => v
    None => abort("expected an integer column")
  }
}

///|
fn req_text(o : String?) -> String {
  match o {
    Some(v) => v
    None => abort("expected a text column")
  }
}

///|
fn team_model() -> @moonorm.Model[Team] {
  @moonorm.Model::new(
    "teams",
    [
      @moonorm.column("id", @moonorm.IntType, primary_key=true),
      @moonorm.column("name", @moonorm.TextType, nullable=false),
    ],
    fn(r) { { id: req_int(r.int(0)), name: req_text(r.text(1)) } },
    fn(t) { [("id", @moonorm.Int(t.id)), ("name", @moonorm.Text(t.name))] },
  )
}

///|
fn hero_model() -> @moonorm.Model[Hero] {
  @moonorm.Model::new(
    "heroes",
    [
      @moonorm.column("id", @moonorm.IntType, primary_key=true),
      @moonorm.column("name", @moonorm.TextType, nullable=false),
      @moonorm.column(
        "team_id",
        @moonorm.IntType,
        references=Some(("teams", "id")),
      ),
    ],
    fn(r) {
      {
        id: req_int(r.int(0)),
        name: req_text(r.text(1)),
        team_id: req_int(r.int(2)),
      }
    },
    fn(h) {
      [
        ("id", @moonorm.Int(h.id)),
        ("name", @moonorm.Text(h.name)),
        ("team_id", @moonorm.Int(h.team_id)),
      ]
    },
  )
}

///|
test "sqlite: models create_table + insert_record + all round-trip" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  let teams = team_model()
  guard sess.create_table(teams) is Ok(_)
  guard sess.insert_record(teams, { id: 1, name: "avengers" }) is Ok(_)
  guard sess.insert_record(teams, { id: 2, name: "justice-league" }) is Ok(_)
  let all = match sess.all(teams) {
    Ok(ts) => ts
    Err(e) => {
      println(e.to_string())
      abort("select all failed")
    }
  }
  assert_eq(all.length(), 2)
  assert_eq(all[0].id, 1)
  assert_eq(all[0].name, "avengers")
  assert_eq(all[1].name, "justice-league")
  sess.close()
}

///|
test "sqlite: eager-load 1:N children and N:1 parent as mapped records" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  let teams = team_model()
  let heroes = hero_model()
  guard sess.create_table(teams) is Ok(_)
  guard sess.create_table(heroes) is Ok(_)
  guard sess.insert_record(teams, { id: 1, name: "avengers" }) is Ok(_)
  guard sess.insert_record(teams, { id: 2, name: "x-men" }) is Ok(_)
  guard sess.insert_record(heroes, { id: 10, name: "iron-man", team_id: 1 })
    is Ok(_)
  guard sess.insert_record(heroes, { id: 11, name: "hulk", team_id: 1 })
    is Ok(_)
  guard sess.insert_record(heroes, { id: 12, name: "wolverine", team_id: 2 })
    is Ok(_)

  // 1:N — a team's heroes. Match heroes.team_id against the parent's id.
  let avengers : Team = { id: 1, name: "avengers" }
  let rel_children : @moonorm.Relation[Team, Hero] = @moonorm.has_many(
    heroes,
    "team_id",
    fn(t) { @moonorm.Int(t.id) },
  )
  let kids = match sess.load(avengers, rel_children) {
    Ok(hs) => hs
    Err(e) => {
      println(e.to_string())
      abort("load children failed")
    }
  }
  // Exactly the two avengers, none of the x-men — proves the join truly filters.
  assert_eq(kids.length(), 2)
  assert_eq(kids[0].name, "iron-man")
  assert_eq(kids[0].team_id, 1)
  assert_eq(kids[1].name, "hulk")

  // N:1 — a hero's team. Match teams.id against the child's team_id.
  let wolverine : Hero = { id: 12, name: "wolverine", team_id: 2 }
  let rel_parent : @moonorm.Relation[Hero, Team] = @moonorm.belongs_to(
    teams,
    "id",
    fn(h) { @moonorm.Int(h.team_id) },
  )
  let team = match sess.load_one(wolverine, rel_parent) {
    Ok(t) => t
    Err(e) => {
      println(e.to_string())
      abort("load parent failed")
    }
  }
  assert_eq(team, Some({ id: 2, name: "x-men" }))
  sess.close()
}

///|
test "sqlite: SAVEPOINT rollback undoes nested work, keeps outer" {
  let sess = @moonorm.Session::new(open_or_fail(":memory:"))
  let teams = team_model()
  guard sess.create_table(teams) is Ok(_)
  guard sess.begin() is Ok(_)
  guard sess.insert_record(teams, { id: 1, name: "kept" }) is Ok(_)
  guard sess.savepoint("sp1") is Ok(_)
  guard sess.insert_record(teams, { id: 2, name: "undone" }) is Ok(_)
  // Undo only the work after the savepoint; the outer INSERT must survive.
  guard sess.rollback_to("sp1") is Ok(_)
  guard sess.release("sp1") is Ok(_)
  guard sess.commit() is Ok(_)
  let all = match sess.all(teams) {
    Ok(ts) => ts
    Err(_) => abort("select all failed")
  }
  assert_eq(all.length(), 1)
  assert_eq(all[0].name, "kept")
  // An invalid savepoint name is refused before it can reach the database.
  assert_eq(sess.savepoint("sp; DROP TABLE teams") is Err(_), true)
  sess.close()
}
