// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Rewrite moondb's dialect-neutral `?` positional placeholders into
/// PostgreSQL's numbered `$1`, `$2`, … form. moondb fixes the *calling
/// convention* (an ordered params array) but leaves the placeholder spelling to
/// the driver; PostgreSQL's extended-query protocol requires `$n`, so a query
/// layer that emits `?` for portability is translated here before Parse.
///
/// A `?` is only a placeholder in SQL text — never inside a single-quoted string
/// literal, a dollar-quoted string, a `"`-quoted identifier, or a `--` / `/* */`
/// comment. Those spans are scanned through verbatim so a literal `?` in data or
/// a comment is left untouched and does not shift the parameter numbering. A
/// literal `?` an application genuinely needs in output can be written `??`,
/// which collapses to a single `?` (mirroring JDBC-style escaping).
pub fn translate_placeholders(sql : String) -> String {
  let sb = StringBuilder()
  let n = sql.length()
  let mut i = 0
  let mut param = 0
  while i < n {
    let c = sql[i]
    if c == '\'' {
      // single-quoted string literal: '' is an escaped quote
      sb.write_char('\'')
      i += 1
      while i < n {
        let d = sql[i]
        sb.write_char(d.unsafe_to_char())
        if d == '\'' {
          if i + 1 < n && sql[i + 1] == '\'' {
            sb.write_char('\'')
            i += 2
            continue
          }
          i += 1
          break
        }
        i += 1
      }
    } else if c == '"' {
      // double-quoted identifier: "" is an escaped quote
      sb.write_char('"')
      i += 1
      while i < n {
        let d = sql[i]
        sb.write_char(d.unsafe_to_char())
        if d == '"' {
          if i + 1 < n && sql[i + 1] == '"' {
            sb.write_char('"')
            i += 2
            continue
          }
          i += 1
          break
        }
        i += 1
      }
    } else if c == '$' && i + 1 < n && is_dollar_tag_char(sql[i + 1], true) {
      // dollar-quoted string: $tag$ ... $tag$
      let tag_end = dollar_tag_end(sql, i)
      if tag_end < 0 {
        sb.write_char('$')
        i += 1
      } else {
        let tag = sql[i:tag_end + 1].to_owned()
        push_str(sb, tag)
        i = tag_end + 1
        // scan body until the matching closing tag
        let close = find_substring(sql, tag, i)
        if close < 0 {
          while i < n {
            sb.write_char(sql[i].unsafe_to_char())
            i += 1
          }
        } else {
          let body = sql[i:close + tag.length()].to_owned()
          push_str(sb, body)
          i = close + tag.length()
        }
      }
    } else if c == '-' && i + 1 < n && sql[i + 1] == '-' {
      // line comment to end of line
      while i < n && sql[i] != '\n' {
        sb.write_char(sql[i].unsafe_to_char())
        i += 1
      }
    } else if c == '/' && i + 1 < n && sql[i + 1] == '*' {
      // block comment (PostgreSQL nests them)
      sb.write_char('/')
      sb.write_char('*')
      i += 2
      let mut depth = 1
      while i < n && depth > 0 {
        if i + 1 < n && sql[i] == '/' && sql[i + 1] == '*' {
          depth += 1
          sb.write_char('/')
          sb.write_char('*')
          i += 2
        } else if i + 1 < n && sql[i] == '*' && sql[i + 1] == '/' {
          depth -= 1
          sb.write_char('*')
          sb.write_char('/')
          i += 2
        } else {
          sb.write_char(sql[i].unsafe_to_char())
          i += 1
        }
      }
    } else if c == '?' {
      if i + 1 < n && sql[i + 1] == '?' {
        sb.write_char('?')
        i += 2
      } else {
        param += 1
        sb.write_char('$')
        push_str(sb, param.to_string())
        i += 1
      }
    } else {
      sb.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  sb.to_string()
}

///|
/// The number of `?` placeholders [`translate_placeholders`] would consume — the
/// count of parameters a statement expects. Shares the same scanner discipline
/// so `??` escapes and quoted/comment spans do not count.
pub fn count_placeholders(sql : String) -> Int {
  let translated = translate_placeholders(sql)
  // The translation is 1:1 on placeholder count; recount `$n` we emitted by
  // re-running the scan is wasteful, so instead count during a light re-scan.
  // Simpler and correct: highest `$n` emitted equals the parameter count.
  let n = translated.length()
  let mut i = 0
  let mut max = 0
  while i < n {
    let c = translated[i]
    if c == '$' &&
      i + 1 < n &&
      translated[i + 1] >= '0' &&
      translated[i + 1] <= '9' {
      i += 1
      let mut v = 0
      while i < n && translated[i] >= '0' && translated[i] <= '9' {
        v = v * 10 + (translated[i].to_int() - 48)
        i += 1
      }
      if v > max {
        max = v
      }
    } else {
      i += 1
    }
  }
  max
}

///|
fn push_str(sb : StringBuilder, s : String) -> Unit {
  for i in 0..<s.length() {
    sb.write_char(s[i].unsafe_to_char())
  }
}

///|
fn is_dollar_tag_char(c : UInt16, first : Bool) -> Bool {
  let ci = c.to_int()
  if ci == 36 {
    return true // '$' closes the tag
  }
  let is_alpha = (ci >= 65 && ci <= 90) || (ci >= 97 && ci <= 122) || ci == 95
  if first {
    is_alpha
  } else {
    is_alpha || (ci >= 48 && ci <= 57)
  }
}

///|
/// Index of the `$` that closes a dollar-quote tag beginning at `start`, or `-1`
/// if the run from `start` is not a valid opening tag.
fn dollar_tag_end(sql : String, start : Int) -> Int {
  let n = sql.length()
  let mut i = start + 1
  while i < n {
    let c = sql[i]
    if c == '$' {
      return i
    }
    if !is_dollar_tag_char(c, false) {
      return -1
    }
    i += 1
  }
  -1
}

///|
/// First index ≥ `from` at which `needle` occurs in `hay`, or `-1`.
fn find_substring(hay : String, needle : String, from : Int) -> Int {
  let hn = hay.length()
  let nn = needle.length()
  if nn == 0 {
    return from
  }
  let mut i = from
  while i + nn <= hn {
    let mut j = 0
    while j < nn && hay[i + j] == needle[j] {
      j += 1
    }
    if j == nn {
      return i
    }
    i += 1
  }
  -1
}
