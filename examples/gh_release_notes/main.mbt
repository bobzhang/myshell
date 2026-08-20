///|
/// Draft markdown release notes from recently merged PRs, grouped by
/// conventional-commit kind.
///
/// The shell version interleaves jq and sed and still needs a loop:
///
///   gh pr list --state merged --json number,title | jq -r '...' | sed ... | sort
///
/// Here `gh` answers once, JSON pattern matching pulls each PR apart, and the
/// same `lexmatch` classifier used in examples/git_report sorts titles into
/// sections.
///
///   moon run --target native examples/gh_release_notes [owner/repo] [limit]

///|
/// The conventional-commit kind of a PR title: "fix: ..." gives "fix",
/// "refactor(glob)!: ..." gives "refactor", anything else "other".
fn kind_of(title : StringView) -> String {
  lexmatch title with longest {
    (re"^[a-z]+" as kind, after=rest) =>
      lexmatch rest {
        (re"^(\([^)]*\))?!?:", after=_detail) => kind.to_owned()
        _ => "other"
      }
    _ => "other"
  }
}

///|
let section_order : Array[String] = [
  "feat", "fix", "perf", "refactor", "docs", "test",
]

///|
async fn main {
  let (repo, limit) : (Array[String], String) = match @env.args() {
    [_, name, limit, ..] => (["-R", name], limit)
    [_, name] => (["-R", name], "30")
    _ => ([], "30")
  }
  let output = @myshell.Cmd(
    "gh",
    [
      ..repo, "pr", "list", "--state", "merged", "--json", "number,title", "--limit",
      limit,
    ],
  ).output()
  if !output.success() {
    println("gh failed: \{output.stderr.trim()}")
    return
  }
  guard @json.parse(output.stdout) is Array(pr_items) else {
    println("unexpected gh output")
    return
  }
  let sections : Map[String, Array[String]] = Map([])
  for item in pr_items {
    guard item is { "number": Number(number, ..), "title": String(title), .. } else {
      continue
    }
    sections
    .get_or_init(kind_of(title), () => [])
    .push("- \{title} (#\{number.to_int()})")
  }
  println("## What's Changed\n")
  let remaining = sections.keys().filter(k => !section_order.contains(k))
  for kind in [..section_order, ..remaining] {
    guard sections.get(kind) is Some(lines) else { continue }
    println("### \{kind}\n")
    for line in lines {
      println(line)
    }
    println("")
  }
}
