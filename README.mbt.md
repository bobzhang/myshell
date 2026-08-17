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

## 1. Run one command

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = Process::run(Cmd::new("printf", ["hello"]))
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
  let output = Process::run(Cmd::new("printf", ["%s", "$(echo no) | *"]))
  assert_eq(output.stdout, "$(echo no) | *")
}
```

## 3. Add arguments

Builders return copies, so a reusable base command is not mutated.

```mbt check
///|
test {
  let git = Cmd::new("git", [])
  let status = git.args(["status", "--short"])
  let diff = git.arg("diff")
  debug_inspect(status.arguments(), content="[\"status\", \"--short\"]")
  debug_inspect(diff.arguments(), content="[\"diff\"]")
  debug_inspect(git.arguments(), content="[]")
}
```

## 4. Pipe commands

Every stage is separately visible to the process host. The stages use real
operating-system pipes and run concurrently in one structured task group.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let plan = Pipeline::new([
    Cmd::new("printf", ["alpha\nbeta\n"]),
    Cmd::new("grep", ["beta"]),
    Cmd::new("tr", ["a-z", "A-Z"]),
  ])
  let output = Process::pipeline(plan)
  assert_eq(output.stdout, "BETA\n")
  assert_eq(output.stage_exit_codes, [0, 0, 0])
}
```

The equivalent incremental form is deliberately ordinary:

```mbt check
///|
test {
  let plan = Cmd::new("printf", ["hello"])
    .pipe(Cmd::new("cat", []))
    .pipe(Cmd::new("wc", ["-c"]))
  assert_eq(plan.commands().length(), 3)
}
```

## 5. Supply standard input

Standard input is closed by default, so non-interactive runs cannot
accidentally wait on ambient input. `stdin` on the first stage also feeds a
pipeline.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let plan = Cmd::new("cat", [])
    .stdin("hello")
    .pipe(Cmd::new("tr", ["a-z", "A-Z"]))
  let output = Process::pipeline(plan)
  assert_eq(output.stdout, "HELLO")
}
```

## 6. Set cwd and environment

```mbt check
///|
test {
  let command = Cmd::new("tool", ["check"])
    .cwd("workspace")
    .env("NO_COLOR", "1")
  debug_inspect(command.working_directory(), content="Some(\"workspace\")")
  assert_eq(command.environment()["NO_COLOR"], "1")
}
```

Use `.clear_env()` before `.env(...)` to start with an empty environment.

## 7. Inspect exit status

`Process::run` does not turn a non-zero exit status into an exception. Use
ordinary MoonBit control flow or call `check()` when failure should raise.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = Process::run(Cmd::new("false", []))
  if !output.success() {
    assert_eq(output.exit_code, 1)
  }
}
```

## 8. Pipeline status uses pipefail

`exit_code` is the rightmost non-zero stage status, or zero when all stages
succeed. Every individual status remains available in `stage_exit_codes`.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  let output = Process::pipeline(
    Pipeline::new([Cmd::new("false", []), Cmd::new("cat", [])]),
  )
  assert_eq(output.exit_code, 1)
  assert_eq(output.stage_exit_codes, [1, 0])
}
```

## 9. Capture stderr

For pipelines, `stage_stderr` preserves one string per stage and `stderr`
concatenates them in stage order. Raw output remains available as
`stdout_bytes`, `stderr_bytes`, and `stage_stderr_bytes`; the text fields use
lossy UTF-8 decoding so arbitrary process output cannot cancel sibling stages.

```mbt check
///|
test {
  let output : Output = {
    exit_code: 1,
    stage_exit_codes: [1],
    stdout_bytes: b"",
    stdout: "",
    stderr_bytes: b"problem\n",
    stderr: "problem\n",
    stage_stderr_bytes: [b"problem\n"],
    stage_stderr: ["problem\n"],
  }
  assert_eq(output.stage_stderr[0], "problem\n")
}
```

## 10. Add a timeout

A timeout cancels the structured task and immediately kills each direct child.
It is not a process-tree deadline: descendants must be contained and reaped by
the host's native process sandbox.

```mbt check
///|
#cfg(not(platform="windows"))
async test {
  try Process::run(Cmd::new("sleep", ["1"]), timeout=20) catch {
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
let output = Process::run(command, max_output_bytes=32 * 1024 * 1024)
```

If all captured streams together exceed the limit, execution raises
`ProcessError::OutputLimitExceeded` and cancels the structured process group.

## One-file use

After the package is published, a complete sandboxed probe can be run without
creating a project:

```sh
moon run -e 'import {
  "bobzhang/myshell",
  "moonbitlang/async",
}

async fn main {
  let output = @myshell.Process::pipeline(
    @myshell.Pipeline::new([
      @myshell.Cmd::new("printf", ["hello\nworld\n"]),
      @myshell.Cmd::new("grep", ["world"]),
    ]),
  )
  print(output.stdout)
}'
```

## Security boundary

This package removes shell parsing and keeps each process invocation structured;
it does not decide which executables or effects are safe. On `wasm`, the host
still owns executable authorization and the native process sandbox. A strong
deployment should grant each child only the filesystem, network, environment,
and secret capabilities required for that invocation.

MoonBit's current `moonrun` policy gates process spawning as a boolean. Enabling
`process.spawn` does **not** apply the policy's filesystem or network restrictions
to the native child; the child receives host-user ambient access. Production
agent runtimes therefore need the separate native `exec-sandbox` described in
the architecture, with child capabilities no greater than the parent grant.
