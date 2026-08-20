# check_triage

Triage the diagnostics of `moon check --json` for any MoonBit project: group
them by file and print them in source order, worst file first. The
shell-and-jq version:

```sh
moon check --json | jq -r '.diagnostics[].path' | sort | uniq -c | sort -rn
```

Here the report is destructured with native JSON pattern matching instead:

```sh
moon run --target native examples/check_triage [project-dir]
```

Sample output for a project with warnings:

```text
success: 2 diagnostics
  warning: 2

/tmp/probe/lib.mbt (2)
  L2 [warning] Warning (unused_value): Unused function 'unused_helper'
  L3 [warning] Warning (unused_value): Unused variable 'y'
```

## How it works

`moon check --json` emits one document; a `guard` states the expected shape
and every diagnostic is pulled apart the same way — no jq, no KeyError:

```mbt check
///|
test "destructure a moon check --json report" {
  let report : Json = {
    "version": 1,
    "status": "success",
    "diagnostics": [
      {
        "level": "warning",
        "path": "lib.mbt",
        "loc": "3:7-3:8",
        "message": "Warning (unused_value): Unused variable 'y'",
      },
    ],
  }
  guard report
    is { "diagnostics": Array(diagnostics), "status": String(status), .. } else {
    fail("unexpected report shape")
  }
  inspect(status, content="success")
  guard diagnostics is [{ "path": String(path), "loc": String(loc), .. }] else {
    fail("unexpected diagnostic shape")
  }
  inspect(path, content="lib.mbt")
  inspect(loc, content="3:7-3:8")
}
```

The `loc` field stays a string in the report; `lexmatch` takes the leading
line number without `cut -d: -f1`:

```mbt check
///|
test "take a loc apart with lexmatch" {
  let line = lexmatch "12:4-12:17" {
    (re"^[0-9]+" as line, after=_rest) =>
      @string.parse_int(line) catch {
        _ => 0
      }
    _ => 0
  }
  inspect(line, content="12")
}
```

`moon check` exits non-zero when there are errors, but the JSON report is
complete either way, so the program parses the report rather than checking
the exit code.
