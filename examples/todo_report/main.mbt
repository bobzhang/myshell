///|
/// Report TODO/FIXME/HACK markers in this module's sources, grouped by file.
///
/// The shell version:
///
///   grep -nE "TODO|FIXME|HACK" *.mbt | cut -d: -f1 | sort | uniq -c | sort -rn
///
/// `glob` expands `*.mbt` as an inspectable value and each match reaches grep
/// as one literal argument, so a filename with a space or a `*` in it cannot
/// be re-split or re-expanded. The `file:line:text` output is parsed with a
/// compiled regex literal and named groups instead of `cut`, and a Map
/// replaces `sort | uniq -c`.
///
///   moon run examples/todo_report

///|
let hit_pattern : @string.Regex = re"^(?<file>[^:]+):(?<line>[0-9]+):(?<text>.*)$"

///|
async fn main {
  let sources = @myshell.glob("*.mbt")
  if sources is [] {
    println("no .mbt sources here")
    return
  }
  // -H forces the file prefix even when the glob matched a single file.
  let hits = @myshell.Cmd("grep", ["-HnE", "TODO|FIXME|HACK", ..sources]).output()
  if hits.exit_code > 1 {
    // grep exits 0 on matches and 1 on none; only 2+ is a real failure.
    println("grep failed: \{hits.stderr}")
    return
  }
  let by_file : Map[String, Array[(Int, String)]] = Map([])
  let mut total = 0
  for line in hits.stdout.split("\n") {
    guard hit_pattern.execute(line) is Some(m) else { continue }
    guard (m.named_group("file"), m.named_group("line"), m.named_group("text"))
      is (Some(file), Some(number), Some(text)) else {
      continue
    }
    let line_number = @string.parse_int(number)
    total += 1
    by_file
    .get_or_init(file.to_owned(), () => [])
    .push((line_number, text.trim().to_owned()))
  }
  if by_file.is_empty() {
    println("clean: no markers in \{sources.length()} files")
    return
  }
  println(
    "\{total} markers in \{by_file.length()} of \{sources.length()} files",
  )
  let files = by_file.to_array()
  files.sort_by_key(entry => -entry.1.length())
  for entry in files {
    let (file, items) = entry
    println("\n\{file} (\{items.length()})")
    for item in items {
      println("  L\{item.0}  \{item.1}")
    }
  }
}
