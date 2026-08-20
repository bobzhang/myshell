# todo_report

TODO/FIXME/HACK markers in this module's sources, grouped by file. The shell
version:

```sh
grep -nE "TODO|FIXME|HACK" *.mbt | cut -d: -f1 | sort | uniq -c | sort -rn
```

Here `glob` expands `*.mbt` as an inspectable value and each match reaches
grep as one literal argument, so a filename with a space or a `*` in it
cannot be re-split or re-expanded:

```sh
moon run --target native examples/todo_report
```

Sample output for a directory with one marker:

```text
1 markers in 1 of 1 files

lib.mbt (1)
  L7  // TODO: delete this probe file
```

## How it works

`glob_matches` is the same pattern language `glob` uses on disk, as a pure
function — which makes the expansion rules easy to state as tests:

```mbt check
///|
test "the pattern language, without touching disk" {
  assert_true(@myshell.glob_matches("*.mbt", "cmd.mbt"))
  assert_false(@myshell.glob_matches("*.mbt", "src/cmd.mbt"))
  assert_false(@myshell.glob_matches("*", ".hidden"))
}
```

The `file:line:text` lines from grep come apart with a compiled regex
literal and named groups instead of `cut`:

```mbt check
///|
test "take grep output apart with named groups" {
  let pattern : @string.Regex = re"^(?<file>[^:]+):(?<line>[0-9]+):(?<text>.*)$"
  guard pattern.execute("glob.mbt:42:// TODO fix this") is Some(m) else {
    fail("expected a match")
  }
  inspect(m.named_group("file").unwrap_or("?"), content="glob.mbt")
  inspect(m.named_group("line").unwrap_or("?"), content="42")
  inspect(m.named_group("text").unwrap_or("?"), content="// TODO fix this")
}
```

grep exits 0 on matches and 1 on none, so the program treats only exit codes
above 1 as failure — ordinary MoonBit control flow where a shell script would
need `set -e` exceptions.
