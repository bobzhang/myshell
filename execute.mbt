///|
/// Default aggregate limit for captured stdout and stderr: 8 MiB.
pub let default_max_output_bytes : Int = 8 * 1024 * 1024

///|
/// What the caller wants done with the streams a stage marks `Capture`.
priv enum Sink {
  /// Collect into `Output`, bounded by the given aggregate byte limit.
  Buffer(Int)
  /// Deliver final stdout one line at a time; nothing is accumulated.
  Lines(async (String) -> Unit)
  /// Keep nothing; a `Capture` stream falls back to the parent's descriptor.
  Discard
}

///|
/// Execute this command and capture stdout and stderr.
///
/// Constructing a `Cmd` does not execute it. Captured stdout and stderr share
/// `max_output_bytes`; streams sent elsewhere by `stdout` or `stderr` do not
/// count against it and arrive empty in `Output`. When `timeout_ms` expires,
/// the direct child is killed immediately; descendants require enforcement by
/// the host's native process sandbox.
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
  validate_output_limit(max_output_bytes)
  Pipeline::{ commands: [self] }.execute(Buffer(max_output_bytes), timeout_ms)
}

///|
/// Execute this command without capturing stdout or stderr.
///
/// Streams left as `Capture` are inherited by the current process, because
/// `status` has no channel to return them on; explicit `ToFile`,
/// `AppendToFile`, and `Inherit` settings still apply. This method returns
/// only the exit status and has no capture limit.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   assert_eq(@myshell.Cmd("false", []).status(), 1)
/// }
/// ```
pub async fn Cmd::status(self : Cmd, timeout_ms? : Int) -> Int {
  Pipeline::{ commands: [self] }.execute(Discard, timeout_ms).exit_code
}

///|
/// Execute this command, delivering standard output one line at a time.
///
/// `on_line` receives each line without its terminator, as soon as the child
/// flushes it, so a long-running command can report progress instead of
/// arriving as one block at the end. Nothing is accumulated, so there is no
/// capture limit. A trailing fragment with no newline is delivered as a final
/// line. Standard error follows the same rule as in `status`.
///
/// Raises `StdoutNotCaptured` when `stdout` sends the stream elsewhere, since
/// there would be nothing to read.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   let seen = []
///   let code = @myshell.Cmd("printf", ["a\nb\n"]).each_line(line => {
///     seen.push(line)
///   })
///   assert_eq(code, 0)
///   assert_eq(seen, ["a", "b"])
/// }
/// ```
pub async fn Cmd::each_line(
  self : Cmd,
  on_line : async (String) -> Unit,
  timeout_ms? : Int,
) -> Int {
  Pipeline::{ commands: [self] }.execute(Lines(on_line), timeout_ms).exit_code
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
  validate_output_limit(max_output_bytes)
  self.execute(Buffer(max_output_bytes), timeout_ms)
}

///|
/// Execute this pipeline, delivering the last stage's output one line at a
/// time.
///
/// The returned status uses the same pipefail rule as `output`. See
/// `Cmd::each_line` for how lines are delivered.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   let seen = []
///   @myshell.Pipeline([Cmd("printf", ["alpha\nbeta\n"]), Cmd("grep", ["beta"])]).each_line(line => {
///       seen.push(line)
///     },
///   )
///   |> ignore
///   assert_eq(seen, ["beta"])
/// }
/// ```
pub async fn Pipeline::each_line(
  self : Pipeline,
  on_line : async (String) -> Unit,
  timeout_ms? : Int,
) -> Int {
  self.execute(Lines(on_line), timeout_ms).exit_code
}

///|
/// Validate the whole plan, then run it under an optional deadline.
async fn Pipeline::execute(
  self : Pipeline,
  sink : Sink,
  timeout_ms : Int?,
) -> Output {
  let count = self.commands.length()
  if count == 0 {
    raise ProcessError::EmptyPipeline
  }
  for index, cmd in self.commands {
    validate_cmd(cmd)
    if index > 0 && cmd.stdin is Some(_) {
      raise StdinOnNonFirstStage(index)
    }
    if index + 1 < count && !(cmd.stdout is Capture) {
      raise RedirectOnNonFinalStage(index)
    }
  }
  if sink is Lines(_) && !(self.commands[count - 1].stdout is Capture) {
    raise StdoutNotCaptured
  }
  match timeout_ms {
    None => run_pipeline(self, sink)
    Some(milliseconds) =>
      @async.with_timeout(milliseconds, () => run_pipeline(self, sink))
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
  if cmd.stdin is Some(FromFile(path)) && path.contains("\u{0000}") {
    raise NulByte("standard input path")
  }
  validate_redirect(cmd.stdout, "standard output path")
  validate_redirect(cmd.stderr, "standard error path")
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
fn validate_redirect(
  redirect : Redirect,
  location : String,
) -> Unit raise ProcessError {
  if redirect is (ToFile(path) | AppendToFile(path)) &&
    path.contains("\u{0000}") {
    raise NulByte(location)
  }
}

///|
fn validate_output_limit(limit : Int) -> Unit raise ProcessError {
  if limit <= 0 {
    raise InvalidOutputLimit(limit)
  }
}

///|
/// Turn a `Redirect` into the descriptor a child should receive.
///
/// `None` means the child inherits the parent's descriptor. `capture` is the
/// pipe this run reads from, and is absent when the caller keeps nothing.
async fn resolve_redirect(
  redirect : Redirect,
  capture : @pipe.PipeWrite?,
) -> &@process.ProcessOutput? {
  match redirect {
    Capture => capture.map(writer => writer as &@process.ProcessOutput)
    Inherit => None
    ToFile(path) =>
      Some(@process.redirect_to_file(path, create_mode=CreateOrTruncate))
    AppendToFile(path) =>
      Some(
        @process.redirect_to_file(path, append=true, create_mode=OpenOrCreate),
      )
  }
}

///|
async fn[X] spawn_stage(
  group : @async.TaskGroup[X],
  cmd : Cmd,
  stdin : &@process.ProcessInput,
  stdout : &@process.ProcessOutput?,
  stderr : &@process.ProcessOutput?,
) -> @process.Process {
  @process.spawn(
    group,
    cmd.program,
    cmd.arguments,
    extra_env=cmd.env,
    inherit_env=cmd.inherit_env,
    stdin~,
    stdout?,
    stderr?,
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
    // `FromFile` never reaches here: it is handed to the child directly.
    Some(FromFile(_)) | None => ()
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
/// Deliver every line the child writes, including a final unterminated one.
///
/// This splits `read_some` chunks itself rather than using the reader's
/// `read_until`: that helper decodes strictly, so one invalid byte would abort
/// the run, and it stops early once its internal buffer fills. Decoding here is
/// lossy and per line, matching how `Output` treats captured text.
async fn read_lines(
  reader : @pipe.PipeRead,
  on_line : async (String) -> Unit,
) -> Unit {
  let pending = @buffer.Buffer(size_hint=4096)
  while reader.read_some(max_len=4096) is Some(chunk) {
    let mut start = 0
    for index in 0..<chunk.length() {
      if chunk[index] == b'\n' {
        pending.write_bytesview(chunk[start:index])
        on_line(@utf8.decode_lossy(pending.to_bytes()))
        pending.reset()
        start = index + 1
      }
    }
    pending.write_bytesview(chunk[start:])
  }
  if pending.length() > 0 {
    on_line(@utf8.decode_lossy(pending.to_bytes()))
  }
}

///|
async fn run_pipeline(pipeline : Pipeline, sink : Sink) -> Output {
  let commands = pipeline.commands
  let count = commands.length()
  let owned : Array[(@pipe.PipeRead, @pipe.PipeWrite)] = []
  defer close_pipes(owned)
  //
  // One pipe joins each adjacent pair of stages.
  let links : Array[(@pipe.PipeRead, @pipe.PipeWrite)] = []
  for _ in 0..<(count - 1) {
    let link = @pipe.pipe()
    links.push(link)
    owned.push(link)
  }
  //
  // A stage only needs a stderr pipe when this run keeps its stderr.
  let capture_stderr = sink is Buffer(_)
  let stderr_pipes : Array[(@pipe.PipeRead, @pipe.PipeWrite)?] = []
  for cmd in commands {
    if capture_stderr && cmd.stderr is Capture {
      let pair = @pipe.pipe()
      owned.push(pair)
      stderr_pipes.push(Some(pair))
    } else {
      stderr_pipes.push(None)
    }
  }
  //
  // The final stage needs a stdout pipe unless the caller keeps nothing.
  let final_stdout = if !(sink is Discard) &&
    commands[count - 1].stdout is Capture {
    let pair = @pipe.pipe()
    owned.push(pair)
    Some(pair)
  } else {
    None
  }
  let first_stdin = @pipe.pipe()
  owned.push(first_stdin)
  @async.with_task_group() <| group => {
    let captured = Ref(0)
    let limit = match sink {
      Buffer(limit) => limit
      _ => 0
    }
    //
    // Readers start before the children so a full pipe never deadlocks.
    let stdout_task = match (final_stdout, sink) {
      (Some((reader, _)), Buffer(_)) =>
        Some(
          group.spawn(() => {
            defer reader.close()
            read_bounded(reader, captured, limit, "stdout")
          }),
        )
      (Some((reader, _)), Lines(on_line)) => {
        group.spawn_bg(() => {
          defer reader.close()
          read_lines(reader, on_line)
        })
        None
      }
      _ => None
    }
    let stderr_tasks : Array[@async.Task[Bytes]?] = []
    for pair in stderr_pipes {
      match pair {
        Some((reader, _)) =>
          stderr_tasks.push(
            Some(
              group.spawn(() => {
                defer reader.close()
                read_bounded(reader, captured, limit, "stderr")
              }),
            ),
          )
        None => stderr_tasks.push(None)
      }
    }
    //
    // Standard input for the first stage: a file the child reads itself, or a
    // pipe this task fills.
    let first_input : &@process.ProcessInput = match commands[0].stdin {
      Some(FromFile(path)) => @process.redirect_from_file(path)
      input => {
        group.spawn_bg(allow_failure=true, () => {
          write_standard_input(first_stdin.1, input)
        })
        first_stdin.0
      }
    }
    let processes : Array[@process.Process] = []
    for index, cmd in commands {
      let stdin : &@process.ProcessInput = if index == 0 {
        first_input
      } else {
        links[index - 1].0
      }
      let stdout = if index + 1 < count {
        Some(links[index].1 as &@process.ProcessOutput)
      } else {
        resolve_redirect(cmd.stdout, final_stdout.map(pair => pair.1))
      }
      let stderr = resolve_redirect(
        cmd.stderr,
        stderr_pipes[index].map(pair => pair.1),
      )
      processes.push(spawn_stage(group, cmd, stdin, stdout, stderr))
      //
      // Drop this parent's ends so the reader sees EOF once the child exits.
      if index > 0 {
        links[index - 1].0.close()
      }
      if index + 1 < count {
        links[index].1.close()
      }
      if stderr_pipes[index] is Some((_, writer)) {
        writer.close()
      }
    }
    if final_stdout is Some((_, writer)) {
      writer.close()
    }
    first_stdin.0.close()
    let exit_codes = [ for child in processes => child.wait() ]
    let stdout_bytes = match stdout_task {
      Some(task) => task.wait()
      None => b""
    }
    let stage_stderr_bytes : Array[Bytes] = []
    let stage_stderr : Array[String] = []
    let stderr = StringBuilder()
    for task in stderr_tasks {
      let stage_bytes = match task {
        Some(task) => task.wait()
        None => b""
      }
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
