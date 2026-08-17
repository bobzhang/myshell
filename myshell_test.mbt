///|
test "command builders are immutable and literal" {
  let base = @myshell.Cmd::new("git", ["status"])
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
}

///|
test "pipeline builders are immutable" {
  let first = @myshell.Cmd::new("printf", ["hello"])
  let pipeline = first.pipe(@myshell.Cmd::new("cat", []))
  let longer = pipeline.pipe(@myshell.Cmd::new("wc", ["-c"]))
  inspect(pipeline.commands().length(), content="2")
  inspect(longer.commands().length(), content="3")
}

///|
#cfg(not(platform="windows"))
async test "run captures stdout and passes shell characters literally" {
  let output = @myshell.Process::run(
    @myshell.Cmd::new("printf", ["%s", "$(echo not-executed) | *"]),
  )
  inspect(output.success(), content="true")
  inspect(output.exit_code, content="0")
  debug_inspect(output.stage_exit_codes, content="[0]")
  inspect(output.stdout, content="$(echo not-executed) | *")
  inspect(output.stderr, content="")
}

///|
#cfg(not(platform="windows"))
async test "run captures binary output without cancelling the command" {
  let output = @myshell.Process::run(@myshell.Cmd::new("printf", ["\\377"]))
  inspect(output.success(), content="true")
  assert_eq(output.stdout_bytes, b"\xff")
  inspect(output.stdout, content="�")
}

///|
#cfg(not(platform="windows"))
async test "run supplies stdin, cwd, and environment" {
  let stdin_output = @myshell.Process::run(
    @myshell.Cmd::new("cat", []).stdin("from stdin"),
  )
  inspect(stdin_output.stdout, content="from stdin")
  let env_output = @myshell.Process::run(
    @myshell.Cmd::new("printenv", ["MYSHELL_TEST_VALUE"]).env(
      "MYSHELL_TEST_VALUE", "works",
    ),
  )
  inspect(env_output.stdout.trim(), content="works")
  let cwd_output = @myshell.Process::run(@myshell.Cmd::new("pwd", []).cwd("."))
  inspect(cwd_output.stdout.trim().has_suffix("/myshell"), content="true")
}

///|
#cfg(not(platform="windows"))
async test "pipeline uses real pipes and captures each status" {
  let pipeline = @myshell.Pipeline::new([
    @myshell.Cmd::new("printf", ["alpha\nbeta\ngamma\n"]),
    @myshell.Cmd::new("grep", ["beta"]),
    @myshell.Cmd::new("tr", ["a-z", "A-Z"]),
  ])
  let output = @myshell.Process::pipeline(pipeline)
  inspect(output.success(), content="true")
  inspect(output.stdout, content="BETA\n")
  debug_inspect(output.stage_exit_codes, content="[0, 0, 0]")
  debug_inspect(output.stage_stderr, content="[\"\", \"\", \"\"]")
}

///|
#cfg(not(platform="windows"))
async test "pipeline reports pipefail status" {
  let output = @myshell.Process::pipeline(
    @myshell.Pipeline::new([
      @myshell.Cmd::new("false", []),
      @myshell.Cmd::new("cat", []),
    ]),
  )
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
  try @myshell.Process::run(@myshell.Cmd::new("", [])) catch {
    @myshell.ProcessError::EmptyProgram => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyProgram")
  }
  try @myshell.Process::pipeline(@myshell.Pipeline::new([])) catch {
    @myshell.ProcessError::EmptyPipeline => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected EmptyPipeline")
  }
  try
    @myshell.Process::pipeline(
      @myshell.Pipeline::new([
        @myshell.Cmd::new("first", []),
        @myshell.Cmd::new("second", []).stdin("not allowed"),
      ]),
    )
  catch {
    @myshell.ProcessError::StdinOnNonFirstStage(index) =>
      inspect(index, content="1")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected StdinOnNonFirstStage")
  }
  try
    @myshell.Process::run(
      @myshell.Cmd::new("printf", ["allowed\u{0000}truncated"]),
    )
  catch {
    @myshell.ProcessError::NulByte(location) =>
      inspect(location, content="argument[0]")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected NulByte")
  }
  try
    @myshell.Process::run(@myshell.Cmd::new("printf", []), max_output_bytes=0)
  catch {
    @myshell.ProcessError::InvalidOutputLimit(limit) =>
      inspect(limit, content="0")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidOutputLimit")
  }
}

///|
#cfg(not(platform="windows"))
async test "output capture is bounded across stdout and stderr" {
  try
    @myshell.Process::run(
      @myshell.Cmd::new("printf", ["12345"]),
      max_output_bytes=4,
    )
  catch {
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
  try
    @myshell.Process::run(@myshell.Cmd::new("sleep", ["1"]), timeout=20)
  catch {
    @async.TimeoutError => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected TimeoutError")
  }
}
