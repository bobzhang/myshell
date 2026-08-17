///|
/// Namespace for executing `Cmd` and `Pipeline` values.
///
/// Constructing a command does not execute it. Execution only happens through
/// these methods, which delegate each process to `moonbitlang/async/process`.
pub enum Process {}

///|
/// Default aggregate limit for captured stdout and stderr: 8 MiB.
pub let default_max_output_bytes : Int = 8 * 1024 * 1024

///|
/// Execute this command and capture stdout and stderr.
///
/// Standard input is closed by default. Use `Cmd::stdin` to supply text.
/// Captured stdout and stderr share `max_output_bytes`. When `timeout_ms`
/// expires, the direct child is killed immediately; descendants require
/// enforcement by the host's native process sandbox.
pub async fn Cmd::output(
  self : Cmd,
  timeout_ms? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  let cmd = self.snapshot()
  validate_cmd(cmd)
  validate_output_limit(max_output_bytes)
  let pipeline = Pipeline::Pipeline([cmd])
  match timeout_ms {
    None => run_pipeline(pipeline, max_output_bytes)
    Some(milliseconds) =>
      @async.with_timeout(milliseconds, () => {
        run_pipeline(pipeline, max_output_bytes)
      })
  }
}

///|
/// Execute this command without capturing stdout or stderr.
///
/// The child inherits the current process's stdout and stderr, and this method
/// returns only its exit status. Standard input is closed by default; `stdin`
/// and `stdin_bytes` still apply. Use `output` when captured data is needed.
pub async fn Cmd::status(self : Cmd, timeout_ms? : Int) -> Int {
  let cmd = self.snapshot()
  validate_cmd(cmd)
  match timeout_ms {
    None => run_status(cmd)
    Some(milliseconds) =>
      @async.with_timeout(milliseconds, () => run_status(cmd))
  }
}

///|
/// Execute this pipeline and capture final stdout plus every stage's stderr.
///
/// Stages use real operating-system pipes and run concurrently in one
/// structured task group. `timeout_ms`, when present, applies to the whole
/// pipeline.
pub async fn Pipeline::output(
  self : Pipeline,
  timeout_ms? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  let pipeline = self.snapshot()
  if pipeline.commands_.is_empty() {
    raise ProcessError::EmptyPipeline
  }
  validate_output_limit(max_output_bytes)
  for index, cmd in pipeline.commands_ {
    validate_cmd(cmd)
    if index > 0 && (cmd.stdin_text_ is Some(_) || cmd.stdin_bytes_ is Some(_)) {
      raise StdinOnNonFirstStage(index)
    }
  }
  match timeout_ms {
    None => run_pipeline(pipeline, max_output_bytes)
    Some(milliseconds) =>
      @async.with_timeout(milliseconds, () => {
        run_pipeline(pipeline, max_output_bytes)
      })
  }
}

///|
/// Execute one command and capture stdout and stderr.
///
/// Standard input is closed by default. Use `Cmd::stdin` to supply text.
/// Captured stdout and stderr share the `max_output_bytes` limit (8 MiB by
/// default). When `timeout` expires, the direct child is killed immediately;
/// descendants require enforcement by the host's native process sandbox.
#deprecated("Use Cmd::output instead")
pub async fn Process::run(
  cmd : Cmd,
  timeout? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  cmd.output(timeout_ms?=timeout, max_output_bytes~)
}

///|
/// Execute a pipeline and capture its final stdout and every stage's stderr.
///
/// `Pipeline` uses real operating-system pipes. All stages run concurrently
/// under one structured-concurrency scope. When `timeout` is present, the whole
/// pipeline is cancelled if it does not finish within that many milliseconds.
/// The direct child for each stage is killed immediately on cancellation;
/// descendants require enforcement by the host's native process sandbox.
#deprecated("Use Pipeline::output instead")
pub async fn Process::pipeline(
  pipeline : Pipeline,
  timeout? : Int,
  max_output_bytes? : Int = default_max_output_bytes,
) -> Output {
  pipeline.output(timeout_ms?=timeout, max_output_bytes~)
}

///|
fn validate_cmd(cmd : Cmd) -> Unit raise ProcessError {
  if cmd.program_.is_empty() {
    raise EmptyProgram
  }
  if cmd.program_.contains("\u{0000}") {
    raise NulByte("program")
  }
  for index, argument in cmd.arguments_ {
    if argument.contains("\u{0000}") {
      raise NulByte("argument[\{index}]")
    }
  }
  match cmd.cwd_ {
    Some(directory) if directory.contains("\u{0000}") =>
      raise NulByte("working directory")
    _ => ()
  }
  for name, value in cmd.environment_ {
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
    cmd.program_,
    cmd.arguments_,
    extra_env=cmd.environment_,
    inherit_env=cmd.inherit_environment_,
    stdin~,
    stdout~,
    stderr~,
    cwd?=cmd.cwd_.map(directory => directory[:]),
    no_console_window=cmd.no_console_window_,
    cancel_handler=@process.hard_cancel(),
  )
}

///|
async fn write_standard_input(
  writer : @pipe.PipeWrite,
  text : String?,
  bytes : Bytes?,
) -> Unit {
  defer writer.close()
  match (text, bytes) {
    (Some(text), _) => writer.write(text)
    (None, Some(bytes)) => writer.write(bytes)
    (None, None) => ()
  }
}

///|
async fn run_status(cmd : Cmd) -> Int {
  let (stdin_reader, stdin_writer) = @pipe.pipe()
  defer stdin_reader.close()
  defer stdin_writer.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(allow_failure=true, () => {
      write_standard_input(stdin_writer, cmd.stdin_text_, cmd.stdin_bytes_)
    })
    @process.run(
      cmd.program_,
      cmd.arguments_,
      extra_env=cmd.environment_,
      inherit_env=cmd.inherit_environment_,
      stdin=stdin_reader,
      cwd?=cmd.cwd_.map(directory => directory[:]),
      no_console_window=cmd.no_console_window_,
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
  let commands = pipeline.commands_
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
      write_standard_input(
        first_stdin_writer,
        commands[0].stdin_text_,
        commands[0].stdin_bytes_,
      )
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
    let stderr_bytes = @buffer.Buffer()
    let stderr = StringBuilder()
    for task in stderr_tasks {
      let stage_bytes = task.wait()
      let stage = @utf8.decode_lossy(stage_bytes)
      stage_stderr_bytes.push(stage_bytes)
      stage_stderr.push(stage)
      stderr_bytes.write_bytes(stage_bytes)
      stderr.write_string(stage)
    }
    {
      exit_code: pipefail_exit_code(exit_codes),
      stage_exit_codes: exit_codes,
      stdout_bytes,
      stdout: @utf8.decode_lossy(stdout_bytes),
      stderr_bytes: stderr_bytes.to_bytes(),
      stderr: stderr.to_string(),
      stage_stderr_bytes,
      stage_stderr,
    }
  }
}
