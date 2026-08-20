# myshell

`bobzhang/myshell` is a small, shell-free process EDSL built on
[`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async). It is meant
for sandboxed programs and agents that need a familiar process API without
receiving a shell as ambient authority.

## The invariant

`Cmd` never invokes a shell. The executable and argument vector stay separate,
and every argument is passed literally. `|`, `>`, `&&`, `$()`, and `*` have no
special meaning. Use `Pipeline` for pipes and ordinary MoonBit for control flow.
Embedded NUL characters in process metadata are rejected before spawning rather
than being truncated by an operating-system argv boundary.

The library supports the `wasm` and `native` targets. Its preferred target is
`wasm`, where process creation is delegated through the host operations used by
`moonbitlang/async/process`.

To exercise the included smoke program under MoonBit's deny-by-default Wasm
policy, with only process spawning enabled:

```sh
moon runwasm --experimental-policy examples/moonrun-policy.json cmd/smoke
```

## Install

```sh
moon add bobzhang/myshell
```

Add the async runtime and this library to the executable package:

```moonbit nocheck
///|
import {
  "bobzhang/myshell",
  "moonbitlang/async",
}
```

Use an `async fn main`; MoonBit async code does not use an `await` keyword.

## The whole API

A process is described by one constructor and executed by one method. There are
no builder chains: a `Cmd` is written the way it is read.

```moonbit nocheck
///|
Cmd(
  program,                 // executable name or path
  arguments,               // Array[String], each passed literally
  cwd? : String,           // default: inherited working directory
  env? : Map[String, String], // default: {}
  inherit_env? : Bool,     // default: true
  stdin? : Stdin,          // default: closed
  stdout? : Redirect,      // default: Capture
  stderr? : Redirect,      // default: Capture
  cancel? : Cancel,        // default: Kill
  no_console_window? : Bool, // default: false, Windows only
) -> Cmd

Pipeline(commands : Array[Cmd]) -> Pipeline
```

```moonbit nocheck
///|
enum Stdin {
  Text(String)
  Binary(Bytes)
  FromFile(String)
} // `< path`

///|
enum Redirect {
  Capture
  Inherit
  ToFile(String)
  AppendToFile(String)
} // `> path`, `>> path`
```

Execution: `output` collects the streams, `status` returns only the exit code,
and `each_line` follows standard output as it is produced. All three exist on
`Cmd`; `Pipeline` has `output` and `each_line`.

`Cmd` and `Pipeline` are abstract and immutable. They are read back through
`program()`, `arguments()`, `cwd()`, `env()`, `inherit_env()`, `stdin()`,
`stdout()`, `stderr()`, `cancel()`, `no_console_window()`, and `commands()` — so a plan that
has been inspected is the same plan that runs. `Output`, `Stdin`, and `Redirect`
are transparent, because a result is data and a stream setting is a choice.

## 1. Run one command

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Cmd("printf", ["hello"]).output()
  assert_eq(output.exit_code, 0)
  assert_eq(output.stdout, "hello")
}
```

## 2. Pass shell characters literally

This prints the characters; it does not execute `echo` and does not create a
pipe.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Cmd("printf", ["%s", "$(echo no) | *"]).output()
  assert_eq(output.stdout, "$(echo no) | *")
}
```

## 3. Set cwd and environment

Options are labelled arguments on the constructor, so the whole plan is one
expression.

```mbt check
///|
test {
  let command = @myshell.Cmd("moon", ["check"], cwd="workspace", env={
    "NO_COLOR": "1",
  })
  debug_inspect(command.cwd(), content="Some(\"workspace\")")
  assert_eq(command.env()["NO_COLOR"], "1")
}
```

Pass `inherit_env=false` to start from an empty environment instead of adding
to the parent's.

## 4. Inspect a plan before running it

A plan can be logged, diffed, or checked against a policy before anything is
spawned. Because `Cmd` is immutable, nothing can change it between the check
and the run.

```mbt check
///|
test {
  let command = @myshell.Cmd("rm", ["-rf", "/"])
  assert_eq(command.program(), "rm")
  assert_eq(command.arguments().length(), 2)
}
```

Building a command list is ordinary MoonBit; there is no builder to learn.

```mbt check
///|
test {
  let arguments = ["check"]
  if true {
    arguments.push("--target")
    arguments.push("wasm")
  }
  let command = @myshell.Cmd("moon", arguments)
  assert_eq(command.arguments(), ["check", "--target", "wasm"])
}
```

## 5. Pipe commands

Every stage is separately visible to the process host, and all stages run
concurrently in one structured task group. Adjacent children share one blocking
operating-system pipe created by `@process.pipe()`: payload bytes stay in the
host pipe rather than crossing this process through a relay task. Each end is
owned by the spawn that receives it, so the parent does not keep an extra copy
that could delay EOF.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Pipeline([
    Cmd("printf", ["alpha\nbeta\n"]),
    Cmd("grep", ["beta"]),
    Cmd("tr", ["a-z", "A-Z"]),
  ]).output()
  assert_eq(output.stdout, "BETA\n")
  assert_eq(output.stage_exit_codes, [0, 0, 0])
}
```

## 6. Supply standard input

Standard input is closed by default, so non-interactive runs cannot
accidentally wait on ambient input. `stdin` on the first stage also feeds a
pipeline; giving it to a later stage is rejected.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Pipeline([
    Cmd("cat", [], stdin=Text("hello")),
    Cmd("tr", ["a-z", "A-Z"]),
  ]).output()
  assert_eq(output.stdout, "HELLO")
}
```

Use `Binary` when the input is not text:

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Cmd("cat", [], stdin=Binary(b"\x00\xff")).output()
  assert_eq(output.stdout_bytes, b"\x00\xff")
}
```

## 7. Redirect to and from files

`ToFile` and `AppendToFile` replace a shell's `> path` and `>> path`, and
`FromFile` replaces `< path`. Without them the only shell-free option would be
to capture in memory and write the file yourself.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let path = "/tmp/myshell-readme.log"
  @myshell.Cmd("printf", ["one\n"], stdout=ToFile(path)).status() |> ignore
  @myshell.Cmd("printf", ["two\n"], stdout=AppendToFile(path)).status()
  |> ignore
  let back = @myshell.Cmd("cat", [], stdin=FromFile(path)).output()
  assert_eq(back.stdout, "one\ntwo\n")
  @myshell.Cmd("rm", ["-f", path]).status() |> ignore
}
```

A redirected stream is not captured, so it arrives empty in `Output` and does
not count against `max_output_bytes`. Use `Inherit` to hand a stream to the
parent's own descriptor. Only the last stage of a pipeline may redirect stdout,
since every earlier stage's stdout is the pipe.

## 8. Follow output as it is produced

`output` returns nothing until the command finishes. `each_line` delivers
standard output line by line while the command runs, which is what a
long-running build or test needs in order to report progress. Completed lines
are not retained, so total output is unbounded; `max_line_bytes` (8 MiB by
default) caps one line's content exactly, so a child that never emits a newline
cannot exhaust memory. Both `\n` and `\r\n` are recognised as terminators, and
a CRLF's CR does not count against the limit.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let seen = []
  let code = @myshell.Cmd("printf", ["alpha\nbeta\n"]).each_line(line => {
    seen.push(line)
  })
  assert_eq(code, 0)
  assert_eq(seen, ["alpha", "beta"])
}
```

`Pipeline::each_line` follows the last stage the same way.

## 9. Run without capturing output

Use `status` when stdout and stderr should be inherited by the current process.
It returns only the exit code and has no capture limit.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  assert_eq(@myshell.Cmd("false", []).status(), 1)
}
```

## 10. Inspect exit status

`Cmd::output` does not turn a non-zero exit status into an exception. Use
ordinary MoonBit control flow or call `check()` when failure should raise.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Cmd("false", []).output()
  if !output.success() {
    assert_eq(output.exit_code, 1)
  }
}
```

## 11. Pipeline status uses pipefail

`exit_code` is the rightmost non-zero stage status, or zero when all stages
succeed. Every individual status remains available in `stage_exit_codes`.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Pipeline([Cmd("false", []), Cmd("cat", [])]).output()
  assert_eq(output.exit_code, 1)
  assert_eq(output.stage_exit_codes, [1, 0])
}
```

## 12. Capture stderr

For pipelines, `stage_stderr` preserves one string per stage and `stderr`
concatenates them in stage order. Exact bytes remain available as
`stdout_bytes` and `stage_stderr_bytes`; the text fields use lossy UTF-8
decoding so arbitrary process output cannot cancel sibling stages.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = @myshell.Cmd("/usr/bin/grep", [
    "needle", "/definitely/not/a/real/myshell-file",
  ]).output()
  assert_true(!output.stderr.is_empty())
  assert_eq(output.stage_stderr.length(), 1)
}
```

## 13. Add a timeout

A timeout cancels the structured task and stops each direct child according to
its `cancel` policy, which kills immediately by default — see section 14 to ask
a child to stop first instead. A timeout is not a process-tree deadline:
descendants must be contained and reaped by the host's native process sandbox.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  try @myshell.Cmd("sleep", ["1"]).output(timeout_ms=20) catch {
    @async.TimeoutError => ()
    _ => fail("expected TimeoutError")
  } noraise {
    _ => fail("expected TimeoutError")
  }
}
```

Captured stdout plus stderr is limited to 8 MiB by default. This prevents an
untrusted child from growing the Wasm instance without bound. Override it when
needed:

```mbt nocheck
///|
let output = command.output(max_output_bytes=32 * 1024 * 1024)
```

If all captured streams together exceed the limit, execution raises
`ProcessError::OutputLimitExceeded` and cancels the structured process group.

## 14. Choose how a cancelled child is stopped

Cancellation — from a timeout, a capture limit, or a failing pipeline stage —
kills the child outright by default, so a sandboxed runtime never waits on an
untrusted process. `Graceful` instead asks the child to stop first, with
`SIGTERM` (or `SIGBREAK` on Windows), and kills it only if it is still running
after `grace_ms`. That is what a child needs in order to flush a file or
release a lock.

```mbt check
///|
test {
  let command = @myshell.Cmd("moon", ["check"], cancel=Graceful(grace_ms=2000))
  debug_inspect(command.cancel(), content="Graceful(grace_ms=2000)")
}
```

A graceful teardown delays the cancelling call by up to `grace_ms`, so a
`timeout_ms` of 20 with a `grace_ms` of 1000 raises `TimeoutError` after about a
second rather than after 20 milliseconds. As with any timeout, this reaches only
the direct child; descendants remain the host sandbox's responsibility.

## One-file use

After the package is published, a complete sandboxed probe can be run without
creating a project:

```sh
moon run -e 'import {
  "bobzhang/myshell",
  "moonbitlang/async",
}

async fn main {
  let output = @myshell.Pipeline([
    @myshell.Cmd("/usr/bin/printf", ["hello\nworld\n"], inherit_env=false),
    @myshell.Cmd("/usr/bin/grep", ["world"], inherit_env=false),
  ]).output()
  print(output.stdout)
}'
```

## 15. Expand paths without a shell

A shell expands `*.mbt` into arguments before the command ever runs. `glob` does
the same expansion as an ordinary value, so the result can be inspected, and
each match reaches the child as one literal argument — a filename containing a
space, a quote, or a `*` cannot be re-split or re-expanded on the way.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let sources = @myshell.glob("*.mbt")
  assert_true(sources.contains("execute.mbt"))
  let output = @myshell.Cmd("wc", ["-l", ..sources]).output()
  assert_true(output.success())
}
```

`*` and `?` stay within one path segment, `[a-z]` and `[!a-z]` match a character
from a set, and `**` as a whole segment spans any number of segments. A leading
`.` is matched only by a literal `.`, so neither `*` nor `**` reaches hidden
entries. A trailing separator restricts the result to directories and is kept.
Matches come back in code-unit order with no duplicates, and a pattern that
matches nothing returns an empty array rather than the pattern itself.

Paths are parsed into a root and a list of names, so the same code serves both
platforms. `/` always separates. On Windows a backslash separates too, and a
drive (`C:/x`, `C:\x`), a drive-relative prefix (`C:x`), and a share
(`\\server\share\x`) are recognised as roots; on Unix, where a backslash is not
a separator, it escapes the next character instead.

`**` does not descend symbolic links, which is what keeps a link pointing at an
ancestor from looping forever; a component you name yourself resolves links
normally. A wildcard never produces `.` or `..`, though a pattern may name them,
so `../*` reaches the parent — confining an expansion to a subtree is the
sandbox policy's job rather than this function's. A cancelled expansion stops
rather than returning a partial result as though it were complete.

`glob_matches` is the same pattern language without touching the disk, for
filtering names already in hand:

```mbt check
///|
test {
  assert_true(@myshell.glob_matches("src/**/*.mbt", "src/a/b/cmd.mbt"))
  assert_false(@myshell.glob_matches("*.mbt", "src/cmd.mbt"))
}
```

## Security boundary

This package removes shell parsing and keeps each process invocation structured;
it does not decide which executables or effects are safe. Because a `Cmd` is
immutable and fully readable, a caller can apply its own policy to a plan
before calling `output` or `status` — the description and the execution are
separate steps.

On `wasm`, the host still owns executable authorization and the native process
sandbox. A strong deployment should grant each child only the filesystem,
network, environment, and secret capabilities required for that invocation.

MoonBit's current `moonrun` policy gates process spawning as a boolean. Enabling
`process.spawn` does **not** apply the policy's filesystem or network restrictions
to the native child; the child receives host-user ambient access. Production
agent runtimes therefore need the separate native `exec-sandbox` described in
the architecture, with child capabilities no greater than the parent grant.
