///|
/// Triage the diagnostics of `moon check --json` for any MoonBit project:
/// group them by file and print them in source order, worst file first.
///
/// The shell-and-jq version of this task:
///
///   moon check --json | jq -r '.diagnostics[].path' | sort | uniq -c | sort -rn
///
/// Here nothing passes through a shell: the command is spawned directly, the
/// report is destructured with native JSON pattern matching, and the `loc`
/// field ("12:4-12:17") comes apart with `lexmatch` instead of `cut`.
///
///   moon run examples/check_triage [project-dir]

///|
fn start_line(loc : String) -> Int raise {
  lexmatch loc {
    (re"^[0-9]+" as line, after=_rest) => @string.parse_int(line)
    _ => fail("unrecognized loc: \{loc}")
  }
}

///|
async fn main {
  let dir = if @env.args() is [_, dir, ..] { dir } else { "." }
  let report = @myshell.Cmd("moon", ["check", "--json"], cwd=dir).output()
  // `moon check` exits non-zero when there are errors, but the JSON report is
  // complete either way, so parse it rather than checking the exit code.
  guard @json.parse(report.stdout)
    is { "diagnostics": Array(diagnostics), "status": String(status), .. } else {
    fail("unexpected report: \{report.stderr}")
  }
  let by_file : Map[String, Array[(Int, String, String)]] = Map([])
  let by_level : Map[String, Int] = Map([])
  for diagnostic in diagnostics {
    guard diagnostic
      is {
        "level": String(level),
        "path": String(path),
        "loc": String(loc),
        "message": String(message),
        ..
      } else {
      continue
    }
    by_level[level] = by_level.get(level).unwrap_or(0) + 1
    by_file.get_or_init(path, () => []).push((start_line(loc), level, message))
  }
  if by_file.is_empty() {
    println("\{status}: no diagnostics")
    return
  }
  println("\{status}: \{diagnostics.length()} diagnostics")
  for level, count in by_level {
    println("  \{level}: \{count}")
  }
  let files = by_file.to_array()
  files.sort_by_key(entry => -entry.1.length())
  for entry in files {
    let (path, items) = entry
    items.sort_by_key(item => item.0)
    println("\n\{path} (\{items.length()})")
    for item in items {
      let (line, level, message) = item
      println("  L\{line} [\{level}] \{message}")
    }
  }
}
