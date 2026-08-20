# Examples

Each example is a complete automation program that would conventionally be a
shell one-liner or a python script. Together they exercise the three legs of
shell-free automation in MoonBit: `myshell` for processes, `lexmatch` and
regex literals for text, and native JSON pattern matching for structured
output.

| Example | Replaces | Shows |
| --- | --- | --- |
| `todo_report` | `grep -nE ... *.mbt \| cut \| sort \| uniq -c` | `glob`, literal argv, regex named groups |
| `check_triage` | `moon check --json \| jq \| sort \| uniq -c` | JSON pattern matching, `lexmatch` on `loc` |
| `git_report` | `git log \| sed \| sort \| uniq -c` (twice) | `each_line` streaming, `lexmatch` tokenizing |
| `gh_dashboard` | three `gh ... \| jq` passes and `wait` | concurrent task group, JSON patterns |
| `gh_release_notes` | `gh pr list \| jq \| sed \| sort` | JSON patterns + `lexmatch` classifier |

Run natively (the `gh_*` examples need an authenticated `gh`):

```sh
moon run --target native examples/todo_report
moon run --target native examples/check_triage [project-dir]
moon run --target native examples/git_report [max-commits]
moon run --target native examples/gh_dashboard [owner/repo]
moon run --target native examples/gh_release_notes [owner/repo] [limit]
```

Or sandboxed, under MoonBit's deny-by-default Wasm policy with only process
spawning enabled:

```sh
moon runwasm --experimental-policy examples/moonrun-policy.json examples/git_report
```
