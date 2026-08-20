# gh_release_notes

Draft markdown release notes from recently merged PRs, grouped by
conventional-commit kind. The shell version interleaves jq and sed and still
needs a loop:

```sh
gh pr list --state merged --json number,title | jq -r '...' | sed ... | sort
```

Here `gh` answers once and everything after that is ordinary MoonBit.
Arguments are declared with `@argparse` — usage errors and `--help` arrive as
one rendered message:

```sh
moon run --target native examples/gh_release_notes [owner/repo] [--limit N]
```

Sample output for moonbitlang/core:

```text
## What's Changed

### fix

- fix(regex): reject empty unicode brace escape (#4102)
- fix(base64): decode from UTF-16 code units, not a byte reinterpretation (#4096)

### perf

- perf(list): single-pass two-pointer has_suffix (#4109)
```

## How it works

The classifier is the same `lexmatch` used in examples/git_report, and the
grouping is a Map — testable right here with inline titles:

```mbt check
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
test "group titles into sections" {
  let sections : Map[String, Array[String]] = Map([])
  for
    title in [
      "fix(regex): reject empty unicode brace escape", "perf(list): single-pass two-pointer has_suffix",
      "fix(base64): decode from UTF-16 code units", "promote 20250819",
    ] {
    sections.get_or_init(kind_of(title), () => []).push(title)
  }
  json_inspect(sections, content={
    "fix": [
      "fix(regex): reject empty unicode brace escape", "fix(base64): decode from UTF-16 code units",
    ],
    "perf": ["perf(list): single-pass two-pointer has_suffix"],
    "other": ["promote 20250819"],
  })
}
```
