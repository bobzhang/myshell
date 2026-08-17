///|
/// Default aggregate limit for captured stdout and stderr: 8 MiB.
pub let default_max_output_bytes : Int = 8 * 1024 * 1024

///|
/// Execute this command and capture stdout and stderr.
///
/// Constructing a `Cmd` does not execute it. Captured stdout and stderr share
/// `max_output_bytes`. When `timeout_ms` expires, the direct child is killed
/// immediately; descendants require enforcement by the host's native process
/// sandbox.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   let output = @myshell.Cmd("printf", ["hello"]).output()
///   assert_eq(output.stdout, "hello")
/// }
/// ```
pub async fn Cmd::output(
  self : Cmd,
  timeout_ms? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  validate_cmd(self)
  validate_output_limit(max_output_bytes)
  let pipeline = { commands: [self] }
  with_optional_timeout(timeout_ms, () => {
    run_pipeline(pipeline, max_output_bytes)
  })
}

///|
/// Execute this command without capturing stdout or stderr.
///
/// The child inherits the current process's stdout and stderr, and this method
/// returns only its exit status. `stdin` still applies. Use `output` when
/// captured data is needed.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   assert_eq(@myshell.Cmd("false", []).status(), 1)
/// }
/// ```
pub async fn Cmd::status(self : Cmd, timeout_ms? : Int) -> Int {
  validate_cmd(self)
  with_optional_timeout(timeout_ms, () => run_status(self))
}

///|
/// Execute this pipeline and capture final stdout plus every stage's stderr.
///
/// Stages use real operating-system pipes and run concurrently in one
/// structured task group. `timeout_ms`, when present, applies to the whole
/// pipeline.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   let output = @myshell.Pipeline([
///     Cmd("printf", ["alpha\nbeta\n"]),
///     Cmd("grep", ["beta"]),
///   ]).output()
///   assert_eq(output.stdout, "beta\n")
/// }
/// ```
pub async fn Pipeline::output(
  self : Pipeline,
  timeout_ms? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  if self.commands.is_empty() {
    raise ProcessError::EmptyPipeline
  }
  validate_output_limit(max_output_bytes)
  for index, cmd in self.commands {
    validate_cmd(cmd)
    if index > 0 && cmd.stdin is Some(_) {
      raise StdinOnNonFirstStage(index)
    }
  }
  with_optional_timeout(timeout_ms, () => run_pipeline(self, max_output_bytes))
}

///|
async fn[X] with_optional_timeout(timeout_ms : Int?, body : async () -> X) -> X {
  match timeout_ms {
    None => body()
    Some(milliseconds) => @async.with_timeout(milliseconds, body)
  }
}

///|
fn validate_cmd(cmd : Cmd) -> Unit raise ProcessError {
  if cmd.program.is_empty() {
    raise EmptyProgram
  }
  if cmd.program.contains("\u{0000}") {
    raise NulByte("program")
  }
  for index, argument in cmd.arguments {
    if argument.contains("\u{0000}") {
      raise NulByte("argument[\{index}]")
    }
  }
  if cmd.cwd is Some(directory) && directory.contains("\u{0000}") {
    raise NulByte("working directory")
  }
  for name, value in cmd.env {
    if name.contains("\u{0000}") {
      raise NulByte("environment name")
    }
    if name.is_empty() || name.contains("=") {
      raise InvalidEnvironmentName(name)
    }
    if value.contains("\u{0000}") {
      raise NulByte("environment value for \{name}")
    }
  }
}

///|
fn validate_output_limit(limit : Int) -> Unit raise ProcessError {
  if limit <= 0 {
    raise InvalidOutputLimit(limit)
  }
}

///|
async fn[X] spawn_stage(
  group : @async.TaskGroup[X],
  cmd : Cmd,
  stdin : @pipe.PipeRead,
  stdout : @pipe.PipeWrite,
  stderr : @pipe.PipeWrite,
) -> @process.Process {
  @process.spawn(
    group,
    cmd.program,
    cmd.arguments,
    extra_env=cmd.env,
    inherit_env=cmd.inherit_env,
    stdin~,
    stdout~,
    stderr~,
    cwd?=cmd.cwd.map(directory => directory[:]),
    no_console_window=cmd.no_console_window,
    cancel_handler=@process.hard_cancel(),
  )
}

///|
async fn write_standard_input(writer : @pipe.PipeWrite, input : Stdin?) -> Unit {
  defer writer.close()
  match input {
    Some(Text(text)) => writer.write(text)
    Some(Binary(bytes)) => writer.write(bytes)
    None => ()
  }
}

///|
async fn run_status(cmd : Cmd) -> Int {
  let (stdin_reader, stdin_writer) = @pipe.pipe()
  defer stdin_reader.close()
  defer stdin_writer.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(allow_failure=true, () => {
      write_standard_input(stdin_writer, cmd.stdin)
    })
    @process.run(
      cmd.program,
      cmd.arguments,
      extra_env=cmd.env,
      inherit_env=cmd.inherit_env,
      stdin=stdin_reader,
      cwd?=cmd.cwd.map(directory => directory[:]),
      no_console_window=cmd.no_console_window,
      cancel_handler=@process.hard_cancel(),
    )
  }
}

///|
fn pipefail_exit_code(exit_codes : ArrayView[Int]) -> Int {
  let mut result = 0
  for code in exit_codes {
    if code != 0 {
      result = code
    }
  }
  result
}

///|
fn close_pipes(pipes : Array[(@pipe.PipeRead, @pipe.PipeWrite)]) -> Unit {
  for pair in pipes {
    pair.0.close()
    pair.1.close()
  }
}

///|
async fn read_bounded(
  reader : @pipe.PipeRead,
  captured : Ref[Int],
  limit : Int,
  stream : String,
) -> Bytes {
  let buffer = @buffer.Buffer(size_hint=4096)
  for ;; {
    let remaining = limit - captured.val
    let chunk_size = if remaining < 4096 { remaining + 1 } else { 4096 }
    match reader.read_some(max_len=chunk_size) {
      None => break
      Some(chunk) => {
        let next_total = captured.val + chunk.length()
        if next_total > limit {
          raise OutputLimitExceeded(stream~, limit~)
        }
        captured.val = next_total
        buffer.write_bytes(chunk)
      }
    }
  }
  buffer.to_bytes()
}

///|
async fn run_pipeline(pipeline : Pipeline, max_output_bytes : Int) -> Output {
  let commands = pipeline.commands
  let count = commands.length()
  let links : Array[(@pipe.PipeRead, @pipe.PipeWrite)] = []
  defer close_pipes(links)
  for _ in 0..<(count - 1) {
    links.push(@pipe.pipe())
  }
  let stderr_pipes : Array[(@pipe.PipeRead, @pipe.PipeWrite)] = []
  defer close_pipes(stderr_pipes)
  for _ in 0..<count {
    stderr_pipes.push(@pipe.pipe())
  }
  let (final_stdout_reader, final_stdout_writer) = @pipe.pipe()
  defer final_stdout_reader.close()
  defer final_stdout_writer.close()
  let (first_stdin_reader, first_stdin_writer) = @pipe.pipe()
  defer first_stdin_reader.close()
  defer first_stdin_writer.close()
  @async.with_task_group() <| group => {
    let captured = Ref(0)
    let stdout_task = group.spawn(() => {
      defer final_stdout_reader.close()
      read_bounded(final_stdout_reader, captured, max_output_bytes, "stdout")
    })
    let stderr_tasks : Array[@async.Task[Bytes]] = []
    for pair in stderr_pipes {
      let (reader, _) = pair
      stderr_tasks.push(
        group.spawn(() => {
          defer reader.close()
          read_bounded(reader, captured, max_output_bytes, "stderr")
        }),
      )
    }
    group.spawn_bg(allow_failure=true, () => {
      write_standard_input(first_stdin_writer, commands[0].stdin)
    })
    let processes : Array[@process.Process] = []
    for index, cmd in commands {
      let stdin = if index == 0 {
        first_stdin_reader
      } else {
        links[index - 1].0
      }
      let stdout = if index + 1 == count {
        final_stdout_writer
      } else {
        links[index].1
      }
      let stderr = stderr_pipes[index].1
      let child = spawn_stage(group, cmd, stdin, stdout, stderr)
      processes.push(child)
      stdin.close()
      stdout.close()
      stderr.close()
    }
    let exit_codes : Array[Int] = []
    for child in processes {
      exit_codes.push(child.wait())
    }
    let stdout_bytes = stdout_task.wait()
    let stage_stderr_bytes : Array[Bytes] = []
    let stage_stderr : Array[String] = []
    let stderr = StringBuilder()
    for task in stderr_tasks {
      let stage_bytes = task.wait()
      let stage = @utf8.decode_lossy(stage_bytes)
      stage_stderr_bytes.push(stage_bytes)
      stage_stderr.push(stage)
      stderr.write_string(stage)
    }
    {
      exit_code: pipefail_exit_code(exit_codes),
      stage_exit_codes: exit_codes,
      stdout: @utf8.decode_lossy(stdout_bytes),
      stdout_bytes,
      stderr: stderr.to_string(),
      stage_stderr,
      stage_stderr_bytes,
    }
  }
}
