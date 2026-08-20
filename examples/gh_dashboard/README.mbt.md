# gh_dashboard

A repository dashboard from three `gh` queries: open PRs, CI health, and
issue labels. The shell version runs them one after another and leans on jq:

```sh
gh pr list --json ...    | jq -r '...'
gh run list --json ...   | jq -r '...' | sort | uniq -c
gh issue list --json ... | jq -r '.[].labels[].name' | sort | uniq -c
```

Here the three queries run concurrently in one structured task group
(replacing `&` and `wait`, with no temp files to collect the answers):

```sh
moon run --target native examples/gh_dashboard [owner/repo]
```

Sample output for this repository:

```text
open PRs: 2
  #6 [unreviewed] docs: add five shell-free automation examples (2026-08-20)
  #5 [unreviewed] fix: glob follow-ups, Windows CI, and a red main (2026-08-20)

CI, last 15 runs:
  ci: 1 in progress, 9 success, 5 failure

open issues: 0
```

## How it works

Each `gh` answer is an array of objects. JSON pattern matching states the
expected fields per item — including literal patterns like
`"isDraft": true` — and skips anything that does not match:

```mbt check
///|
test "one pr item" {
  let item : Json = {
    "number": 6,
    "title": "docs: add five shell-free automation examples",
    "isDraft": false,
    "reviewDecision": "",
    "updatedAt": "2026-08-20T09:00:00Z",
  }
  guard item
    is {
      "number": Number(number, ..),
      "title": String(title),
      "reviewDecision": String(decision),
      ..
    } else {
    fail("unexpected item shape")
  }
  inspect(number.to_int(), content="6")
  inspect(title, content="docs: add five shell-free automation examples")
  assert_true(decision is "")
  assert_false(item is { "isDraft": true, .. })
}
```

ISO timestamps stay strings; `lexmatch` trims one down to a day:

```mbt check
///|
test "trim a timestamp to a day" {
  let day = lexmatch "2026-08-20T09:00:00Z" {
    (re"^[0-9]{4}-[0-9]{2}-[0-9]{2}" as day, after=_rest) => day.to_owned()
    _ => "?"
  }
  inspect(day, content="2026-08-20")
}
```

The three fetches run in one `@async.with_task_group`: if any of them fails,
the others are cancelled, and when the group returns every task has
terminated — structure a shell script cannot promise.
