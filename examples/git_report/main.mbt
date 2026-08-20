///|
/// Summarize recent history: commits per author and per conventional-commit
/// kind, streamed straight out of `git log`.
///
/// The shell version needs one pass per table:
///
///   git log -n 500 --pretty=format:%s  | sed -E 's/^([a-z]+).*/\1/' | sort | uniq -c
///   git log -n 500 --pretty=format:%an | sort | uniq -c | sort -rn
///
/// Here it is one process and one pass: `each_line` delivers lines while git
/// is still running (nothing is buffered), `lexmatch` splits and classifies
/// each line, and Maps replace `sort | uniq -c`.
///
///   moon run examples/git_report [max-commits]

///|
/// The conventional-commit kind of a subject line: "fix: ..." gives "fix",
/// "refactor(glob)!: ..." gives "refactor", anything else "other".
fn kind_of(subject : StringView) -> String {
  lexmatch subject with longest {
    (re"^[a-z]+" as kind, after=rest) =>
      lexmatch rest {
        (re"^(\([^)]*\))?!?:", after=_detail) => kind.to_owned()
        _ => "other"
      }
    _ => "other"
  }
}

///|
fn bump(counter : Map[String, Int], key : String) -> Unit {
  counter[key] = counter.get(key).unwrap_or(0) + 1
}

///|
fn print_counts(counter : Map[String, Int]) -> Unit {
  let rows = counter.to_array()
  rows.sort_by_key(row => -row.1)
  for row in rows {
    println("  \{row.1}\t\{row.0}")
  }
}

///|
async fn main {
  let limit = if @env.args() is [_, n, ..] { n } else { "500" }
  let authors : Map[String, Int] = Map([])
  let kinds : Map[String, Int] = Map([])
  let mut commits = 0
  let code = @myshell.Cmd("git", [
    "log", "-n", limit, "--pretty=format:%an%x09%s",
  ]).each_line(line => {
    lexmatch line[:] {
      (re"^[^\t]+" as author, after=rest) => {
        commits += 1
        bump(authors, author.to_owned())
        lexmatch rest {
          (re"^\t", after=subject) => bump(kinds, kind_of(subject))
          _ => ()
        }
      }
      _ => ()
    }
  })
  if code != 0 {
    println("git log failed with exit code \{code}")
    return
  }
  println("\{commits} commits")
  println("\nby kind:")
  print_counts(kinds)
  println("\nby author:")
  print_counts(authors)
}
