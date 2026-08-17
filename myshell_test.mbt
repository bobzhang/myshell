///|
test "a command is a plain, inspectable description" {
  let cmd = @myshell.Cmd("git", ["status", "--short"], cwd="workspace", env={
    "NO_COLOR": "1",
  })
  inspect(cmd.program(), content="git")
  assert_eq(cmd.arguments(), ["status", "--short"])
  debug_inspect(cmd.cwd(), content="Some(\"workspace\")")
  inspect(cmd.env()["NO_COLOR"], content="1")
  inspect(cmd.inherit_env(), content="true")
  debug_inspect(cmd.stdin(), content="None")
  inspect(cmd.no_console_window(), content="false")
}

///|
test "defaults keep a command closed and inherited" {
  let cmd = @myshell.Cmd("true", [])
  debug_inspect(
    cmd,
    content=(
      #|{
      #|  program: "true",
      #|  arguments: [],
      #|  cwd: None,
      #|  env: {},
      #|  inherit_env: true,
      #|  stdin: None,
      #|  stdout: Capture,
      #|  stderr: Capture,
      #|  no_console_window: false,
      #|}
    ),
  )
}

///|
test "a command does not alias the collections it was given" {
  let arguments = ["status"]
  let env = { "NO_COLOR": "1" }
  let cmd = @myshell.Cmd("git", arguments, env~)
  arguments.push("--short")
  env["NO_COLOR"] = "0"
  assert_eq(cmd.arguments(), ["status"])
  inspect(cmd.env()["NO_COLOR"], content="1")
}

///|
test "reading a command back does not expose it to mutation" {
  let cmd = @myshell.Cmd("git", ["status"], env={ "NO_COLOR": "1" })
  let borrowed = cmd.env()
  borrowed["NO_COLOR"] = "0"
  borrowed["INJECTED"] = "yes"
  inspect(cmd.env()["NO_COLOR"], content="1")
  debug_inspect(cmd.env().get("INJECTED"), content="None")
}

///|
test "stdin is text or binary, never both" {
  let text = @myshell.Cmd("cat", [], stdin=Text("hello"))
  let binary = @myshell.Cmd("cat", [], stdin=Binary(b"\x00\xff"))
  debug_inspect(text.stdin(), content="Some(Text(\"hello\"))")
  guard binary.stdin() is Some(Binary(input)) else {
    fail("expected binary standard input")
  }
  assert_eq(input, b"\x00\xff")
}

///|
#cfg(not(platform="windows"))
async test "run captures stdout and passes shell characters literally" {
  let output = @myshell.Cmd("printf", ["%s", "$(echo not-executed) | *"]).output()
  inspect(output.success(), content="true")
  inspect(output.exit_code, content="0")
  debug_inspect(output.stage_exit_codes, content="[0]")
  inspect(output.stdout, content="$(echo not-executed) | *")
  inspect(output.stderr, content="")
}

///|
#cfg(not(platform="windows"))
async test "run captures binary output without cancelling the command" {
  let output = @myshell.Cmd("printf", ["\\377"]).output()
  inspect(output.success(), content="true")
  assert_eq(output.stdout_bytes, b"\xff")
  inspect(output.stdout, content="�")
}

///|
#cfg(not(platform="windows"))
async test "run supplies stdin, cwd, and environment" {
  let stdin_output = @myshell.Cmd("cat", [], stdin=Text("from stdin")).output()
  inspect(stdin_output.stdout, content="from stdin")
  let env_output = @myshell.Cmd("printenv", ["MYSHELL_TEST_VALUE"], env={
    "MYSHELL_TEST_VALUE": "works",
  }).output()
  inspect(env_output.stdout.trim(), content="works")
  let cwd_output = @myshell.Cmd("pwd", [], cwd=".").output()
  inspect(cwd_output.stdout.trim().has_suffix("/myshell"), content="true")
  let clean_output = @myshell.Cmd(
    "/usr/bin/env",
    [],
    env={ "MYSHELL_ONLY": "yes" },
    inherit_env=false,
  ).output()
  inspect(clean_output.stdout, content="MYSHELL_ONLY=yes\n")
}

///|
#cfg(not(platform="windows"))
async test "run supplies binary stdin" {
  let output = @myshell.Cmd("cat", [], stdin=Binary(b"\x00\xff")).output()
  assert_eq(output.stdout_bytes, b"\x00\xff")
}

///|
#cfg(not(platform="windows"))
async test "status returns the exit code without capture" {
  inspect(@myshell.Cmd("true", []).status(), content="0")
  inspect(@myshell.Cmd("false", []).status(), content="1")
  inspect(
    @myshell.Cmd("true", [], no_console_window=true).status(),
    content="0",
  )
}

///|
#cfg(not(platform="windows"))
async test "pipeline uses real pipes and captures each status" {
  let output = @myshell.Pipeline([
    Cmd("printf", ["alpha\nbeta\ngamma\n"]),
    Cmd("grep", ["beta"]),
    Cmd("tr", ["a-z", "A-Z"]),
  ]).output()
  inspect(output.success(), content="true")
  inspect(output.stdout, content="BETA\n")
  debug_inspect(output.stage_exit_codes, content="[0, 0, 0]")
  debug_inspect(output.stage_stderr, content="[\"\", \"\", \"\"]")
}

///|
#cfg(not(platform="windows"))
async test "pipeline reports pipefail status" {
  let output = @myshell.Pipeline([Cmd("false", []), Cmd("cat", [])]).output()
  inspect(output.success(), content="false")
  inspect(output.exit_code, content="1")
  debug_inspect(output.stage_exit_codes, content="[1, 0]")
  try output.check() catch {
    CommandFailed(failed) => inspect(failed.exit_code, content="1")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected CommandFailed")
  }
}

///|
#cfg(not(platform="windows"))
async test "pipeline preserves stderr by stage" {
  let output = @myshell.Pipeline([
    Cmd("/usr/bin/awk", [
      "BEGIN { printf \"first\" > \"/dev/stderr\"; print \"hello\" }",
    ]),
    Cmd("/usr/bin/awk", [
      "{ print } END { printf \"second\" > \"/dev/stderr\" }",
    ]),
  ]).output()
  inspect(output.stdout, content="hello\n")
  debug_inspect(output.stage_stderr, content="[\"first\", \"second\"]")
  debug_inspect(
    output.stage_stderr_bytes,
    content=(
      #|[
      #|  <Bytes: [0x66, 0x69, 0x72, 0x73, 0x74]>,
      #|  <Bytes: [0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64]>,
      #|]
    ),
  )
  inspect(output.stderr, content="firstsecond")
}

///|
async test "invalid plans fail before spawning" {
  try @myshell.Cmd("", []).output() catch {
    @myshell.ProcessError::EmptyProgram => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyProgram")
  }
  try @myshell.Pipeline([]).output() catch {
    @myshell.ProcessError::EmptyPipeline => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyPipeline")
  }
  try
    @myshell.Pipeline([
      Cmd("first", []),
      Cmd("second", [], stdin=Text("not allowed")),
    ]).output()
  catch {
    @myshell.ProcessError::StdinOnNonFirstStage(index) =>
      inspect(index, content="1")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected StdinOnNonFirstStage")
  }
  try @myshell.Cmd("printf", ["allowed\u{0000}truncated"]).output() catch {
    @myshell.ProcessError::NulByte(location) =>
      inspect(location, content="argument[0]")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected NulByte")
  }
  try @myshell.Cmd("printf", [], env={ "BAD=NAME": "value" }).output() catch {
    @myshell.ProcessError::InvalidEnvironmentName(name) =>
      inspect(name, content="BAD=NAME")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidEnvironmentName")
  }
  try @myshell.Cmd("printf", [], env={ "": "value" }).output() catch {
    @myshell.ProcessError::InvalidEnvironmentName(name) =>
      inspect(name, content="")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidEnvironmentName")
  }
  try @myshell.Cmd("printf", []).output(max_output_bytes=0) catch {
    @myshell.ProcessError::InvalidOutputLimit(limit) =>
      inspect(limit, content="0")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidOutputLimit")
  }
}

///|
#cfg(not(platform="windows"))
async test "early stdin close still returns process output" {
  let output = @myshell.Cmd("true", [], stdin=Text("x".repeat(1024 * 1024))).output(
    timeout_ms=1000,
  )
  inspect(output.success(), content="true")
}

///|
#cfg(not(platform="windows"))
async test "output capture is bounded across stdout and stderr" {
  try
    @myshell.Cmd("/usr/bin/awk", [
      "BEGIN { printf \"12\"; printf \"345\" > \"/dev/stderr\" }",
    ]).output(max_output_bytes=4)
  catch {
    @myshell.ProcessError::OutputLimitExceeded(stream~, limit~) => {
      assert_true(stream == "stdout" || stream == "stderr")
      inspect(limit, content="4")
    }
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected OutputLimitExceeded")
  }
}

///|
#cfg(not(platform="windows"))
async test "timeout cancels the child" {
  try @myshell.Cmd("sleep", ["1"]).output(timeout_ms=20) catch {
    @async.TimeoutError => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected TimeoutError")
  }
  try
    @myshell.Pipeline([Cmd("sleep", ["1"]), Cmd("cat", [])]).output(
      timeout_ms=20,
    )
  catch {
    @async.TimeoutError => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected TimeoutError")
  }
}

///|
#cfg(not(platform="windows"))
async test "stdout can be sent to a file and appended to" {
  let path = "/tmp/myshell-redirect-test.txt"
  @myshell.Cmd("printf", ["first\n"], stdout=ToFile(path)).status() |> ignore
  @myshell.Cmd("printf", ["second\n"], stdout=AppendToFile(path)).status()
  |> ignore
  let readback = @myshell.Cmd("cat", [path]).output()
  inspect(readback.stdout, content="first\nsecond\n")
  // `ToFile` truncates, so the appended line is gone again.
  @myshell.Cmd("printf", ["third\n"], stdout=ToFile(path)).status() |> ignore
  inspect(@myshell.Cmd("cat", [path]).output().stdout, content="third\n")
  @myshell.Cmd("rm", ["-f", path]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "a redirected stream is absent from the captured output" {
  let path = "/tmp/myshell-redirect-stderr.txt"
  let output = @myshell.Cmd(
    "/usr/bin/awk",
    ["BEGIN { print \"out\"; print \"err\" > \"/dev/stderr\" }"],
    stderr=ToFile(path),
  ).output()
  inspect(output.stdout, content="out\n")
  inspect(output.stderr, content="")
  inspect(@myshell.Cmd("cat", [path]).output().stdout, content="err\n")
  @myshell.Cmd("rm", ["-f", path]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "stdin can be read from a file" {
  let path = "/tmp/myshell-stdin-source.txt"
  @myshell.Cmd("printf", ["from file\n"], stdout=ToFile(path)).status()
  |> ignore
  let output = @myshell.Cmd("cat", [], stdin=FromFile(path)).output()
  inspect(output.stdout, content="from file\n")
  @myshell.Cmd("rm", ["-f", path]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "each_line delivers stdout incrementally" {
  let seen = []
  let code = @myshell.Cmd("printf", ["alpha\nbeta\ngamma"]).each_line(line => {
    seen.push(line)
  })
  inspect(code, content="0")
  // The unterminated trailing fragment is still delivered.
  assert_eq(seen, ["alpha", "beta", "gamma"])
}

///|
#cfg(not(platform="windows"))
async test "each_line follows the last stage of a pipeline" {
  let seen = []
  let code = @myshell.Pipeline([
    Cmd("printf", ["alpha\nbeta\ngamma\n"]),
    Cmd("grep", ["mm"]),
  ]).each_line(line => seen.push(line))
  inspect(code, content="0")
  assert_eq(seen, ["gamma"])
}

///|
#cfg(not(platform="windows"))
async test "each_line streams past what a buffered limit would allow" {
  let program = "BEGIN { for (i = 0; i < 1000; i++) print \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" }"
  let lines = Ref(0)
  let bytes = Ref(0)
  @myshell.Cmd("/usr/bin/awk", [program]).each_line(line => {
    lines.val = lines.val + 1
    bytes.val = bytes.val + line.length()
  })
  |> ignore
  inspect(lines.val, content="1000")
  inspect(bytes.val, content="30000")
  // The same command cannot be captured under a limit that small.
  try
    @myshell.Cmd("/usr/bin/awk", [program]).output(max_output_bytes=1024)
  catch {
    @myshell.ProcessError::OutputLimitExceeded(_) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected OutputLimitExceeded")
  }
}

///|
async test "redirection is rejected where it would break the plan" {
  try
    @myshell.Pipeline([
      Cmd("first", [], stdout=ToFile("/tmp/nope")),
      Cmd("second", []),
    ]).output()
  catch {
    @myshell.ProcessError::RedirectOnNonFinalStage(index) =>
      inspect(index, content="0")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected RedirectOnNonFinalStage")
  }
  try @myshell.Cmd("printf", [], stdout=Inherit).each_line(_line => ()) catch {
    @myshell.ProcessError::StdoutNotCaptured => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected StdoutNotCaptured")
  }
  try
    @myshell.Cmd("printf", [], stdout=ToFile("bad\u{0000}path")).output()
  catch {
    @myshell.ProcessError::NulByte(location) =>
      inspect(location, content="standard output path")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected NulByte")
  }
}

///|
#cfg(not(platform="windows"))
async test "each_line bounds a single unterminated line" {
  try
    @myshell.Cmd("/usr/bin/awk", [
      "BEGIN { for (i = 0; i < 100; i++) printf \"aaaaaaaaaa\" }",
    ]).each_line(_line => (), max_line_bytes=64)
    |> ignore
  catch {
    @myshell.ProcessError::OutputLimitExceeded(stream~, limit~) => {
      inspect(stream, content="stdout line")
      inspect(limit, content="64")
    }
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected OutputLimitExceeded")
  }
}

///|
#cfg(not(platform="windows"))
async test "each_line strips a CRLF terminator" {
  let seen = []
  @myshell.Cmd("printf", ["a\r\nb\r\nc"]).each_line(line => seen.push(line))
  |> ignore
  assert_eq(seen, ["a", "b", "c"])
}

///|
#cfg(not(platform="windows"))
async test "the line cap applies to terminated lines too" {
  // The line ends with a newline, so it is never held for long — the cap is
  // still a promise about line length, not just about memory.
  try
    @myshell.Cmd("printf", ["%s\n", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]).each_line(
      _line => (),
      max_line_bytes=8,
    )
    |> ignore
  catch {
    @myshell.ProcessError::OutputLimitExceeded(stream~, limit~) => {
      inspect(stream, content="stdout line")
      inspect(limit, content="8")
    }
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected OutputLimitExceeded")
  }
  // A line exactly at the limit is allowed.
  let seen = []
  @myshell.Cmd("printf", ["%s\n", "aaaaaaaa"]).each_line(
    line => seen.push(line),
    max_line_bytes=8,
  )
  |> ignore
  assert_eq(seen, ["aaaaaaaa"])
}

///|
#cfg(not(platform="windows"))
async test "a lone trailing carriage return is data, not a terminator" {
  let seen = []
  @myshell.Cmd("printf", ["a\r\nb\r"]).each_line(line => seen.push(line))
  |> ignore
  // "a\r\n" is a CRLF line; the final "b\r" was never terminated.
  assert_eq(seen, ["a", "b\r"])
}
