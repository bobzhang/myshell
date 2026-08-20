# git_report

Commits per author and per conventional-commit kind, streamed straight out of
`git log`. The shell version needs one pass per table:

```sh
git log -n 500 --pretty=format:%s  | sed -E 's/^([a-z]+).*/\1/' | sort | uniq -c
git log -n 500 --pretty=format:%an | sort | uniq -c | sort -rn
```

Here it is one process and one pass:

```sh
moon run --target native examples/git_report [max-commits]
```

Sample output for this repository:

```text
15 commits

by kind:
  6	feat
  5	fix
  2	refactor
  1	docs
  1	test

by author:
  15	Hongbo Zhang
```

## How it works

`Cmd::each_line` delivers each line while `git` is still running, so nothing
is buffered and total output is unbounded. `lexmatch` splits the
tab-separated line and classifies the subject; two Maps replace
`sort | uniq -c`.

The classifier is ordinary `lexmatch`, small enough to test right here:

```mbt check
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
test "conventional commit kinds" {
  inspect(
    kind_of("fix: treat an escaped leading separator as absolute"),
    content="fix",
  )
  inspect(kind_of("refactor(glob)!: parse paths once"), content="refactor")
  inspect(kind_of("feat(cmd): add graceful cancel"), content="feat")
  inspect(kind_of("Merge branch 'main'"), content="other")
  inspect(kind_of("fixture cleanup"), content="other")
}
```
