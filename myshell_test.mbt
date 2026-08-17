///|
test "command builders are immutable and literal" {
  let base = @myshell.Cmd::Cmd("git", ["status"])
  let configured = base
    .arg("--short")
    .cwd("workspace")
    .env("LC_ALL", "C")
    .clear_env()
    .stdin("input")
  inspect(base.program(), content="git")
  debug_inspect(base.arguments(), content="[\"status\"]")
  debug_inspect(configured.arguments(), content="[\"status\", \"--short\"]")
  debug_inspect(configured.working_directory(), content="Some(\"workspace\")")
  inspect(configured.environment()["LC_ALL"], content="C")
  inspect(configured.inherits_environment(), content="false")
  debug_inspect(configured.standard_input(), content="Some(\"input\")")
  let binary = base.stdin_bytes(b"\x00\xff")
  debug_inspect(binary.standard_input(), content="None")
  guard binary.standard_input_bytes() is Some(input) else {
    fail("expected binary standard input")
  }
  assert_eq(input, b"\x00\xff")
}

///|
test "pipeline builders are immutable" {
  let first = @myshell.Cmd::Cmd("printf", ["hello"])
  let pipeline = first.pipe(Cmd("cat", []))
  let longer = pipeline.pipe(Cmd("wc", ["-c"]))
  inspect(pipeline.commands().length(), content="2")
  inspect(longer.commands().length(), content="3")
}

///|
#cfg(not(platform="windows"))
async test "run captures stdout and passes shell characters literally" {
  let output = @myshell.Cmd::Cmd("printf", ["%s", "$(echo not-executed) | *"]).output()
  inspect(output.success(), content="true")
  inspect(output.exit_code, content="0")
  debug_inspect(output.stage_exit_codes, content="[0]")
  inspect(output.stdout, content="$(echo not-executed) | *")
  inspect(output.stderr, content="")
}

///|
#cfg(not(platform="windows"))
async test "run captures binary output without cancelling the command" {
  let output = @myshell.Cmd::Cmd("printf", ["\\377"]).output()
  inspect(output.success(), content="true")
  assert_eq(output.stdout_bytes, b"\xff")
  inspect(output.stdout, content="�")
}

///|
#cfg(not(platform="windows"))
async test "run supplies stdin, cwd, and environment" {
  let stdin_output = @myshell.Cmd::Cmd("cat", []).stdin("from stdin").output()
  inspect(stdin_output.stdout, content="from stdin")
  let env_output = @myshell.Cmd::Cmd("printenv", ["MYSHELL_TEST_VALUE"])
    .env("MYSHELL_TEST_VALUE", "works")
    .output()
  inspect(env_output.stdout.trim(), content="works")
  let cwd_output = @myshell.Cmd::Cmd("pwd", []).cwd(".").output()
  inspect(cwd_output.stdout.trim().has_suffix("/myshell"), content="true")
}

///|
#cfg(not(platform="windows"))
async test "run supplies binary stdin" {
  let output = @myshell.Cmd::Cmd("cat", []).stdin_bytes(b"\x00\xff").output()
  assert_eq(output.stdout_bytes, b"\x00\xff")
}

///|
#cfg(not(platform="windows"))
async test "status returns the exit code without capture" {
  inspect(@myshell.Cmd::Cmd("true", []).status(), content="0")
  inspect(@myshell.Cmd::Cmd("false", []).status(), content="1")
}

///|
#cfg(not(platform="windows"))
async test "pipeline uses real pipes and captures each status" {
  let pipeline = @myshell.Pipeline::Pipeline([
    Cmd("printf", ["alpha\nbeta\ngamma\n"]),
    Cmd("grep", ["beta"]),
    Cmd("tr", ["a-z", "A-Z"]),
  ])
  let output = pipeline.output()
  inspect(output.success(), content="true")
  inspect(output.stdout, content="BETA\n")
  debug_inspect(output.stage_exit_codes, content="[0, 0, 0]")
  debug_inspect(output.stage_stderr, content="[\"\", \"\", \"\"]")
}

///|
#cfg(not(platform="windows"))
async test "pipeline reports pipefail status" {
  let output = @myshell.Pipeline::Pipeline([Cmd("false", []), Cmd("cat", [])]).output()
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
async test "invalid plans fail before spawning" {
  try @myshell.Cmd::Cmd("", []).output() catch {
    @myshell.ProcessError::EmptyProgram => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyProgram")
  }
  try @myshell.Pipeline::Pipeline([]).output() catch {
    @myshell.ProcessError::EmptyPipeline => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyPipeline")
  }
  try
    @myshell.Pipeline::Pipeline([
      Cmd("first", []),
      @myshell.Cmd::Cmd("second", []).stdin("not allowed"),
    ]).output()
  catch {
    @myshell.ProcessError::StdinOnNonFirstStage(index) =>
      inspect(index, content="1")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected StdinOnNonFirstStage")
  }
  try @myshell.Cmd::Cmd("printf", ["allowed\u{0000}truncated"]).output() catch {
    @myshell.ProcessError::NulByte(location) =>
      inspect(location, content="argument[0]")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected NulByte")
  }
  try @myshell.Cmd::Cmd("printf", []).env("BAD=NAME", "value").output() catch {
    @myshell.ProcessError::InvalidEnvironmentName(name) =>
      inspect(name, content="BAD=NAME")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidEnvironmentName")
  }
  try @myshell.Cmd::Cmd("printf", []).env("", "value").output() catch {
    @myshell.ProcessError::InvalidEnvironmentName(name) =>
      inspect(name, content="")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidEnvironmentName")
  }
  try @myshell.Cmd::Cmd("printf", []).output(max_output_bytes=0) catch {
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
  let output = @myshell.Cmd::Cmd("true", [])
    .stdin("x".repeat(1024 * 1024))
    .output(timeout_ms=1000)
  inspect(output.success(), content="true")
}

///|
#cfg(not(platform="windows"))
async test "output capture is bounded across stdout and stderr" {
  try @myshell.Cmd::Cmd("printf", ["12345"]).output(max_output_bytes=4) catch {
    @myshell.ProcessError::OutputLimitExceeded(stream~, limit~) => {
      inspect(stream, content="stdout")
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
  try @myshell.Cmd::Cmd("sleep", ["1"]).output(timeout_ms=20) catch {
    @async.TimeoutError => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected TimeoutError")
  }
}
