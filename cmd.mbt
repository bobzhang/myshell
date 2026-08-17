///|
/// Where a child process's standard input comes from.
///
/// `Text` is encoded as UTF-8. `Binary` is written verbatim, which is what a
/// child expecting a compressed or otherwise non-textual stream needs.
/// `FromFile` is the structured form of a shell's `< path`; the file must
/// already exist.
pub(all) enum Stdin {
  Text(String)
  Binary(Bytes)
  FromFile(String)
} derive(Debug)

///|
/// Where a child process's standard output or standard error goes.
///
/// `Capture` returns the stream to the caller: `output` collects it into
/// `Output`, `each_line` delivers stdout line by line, and `status` has no
/// return channel so it inherits instead. `Inherit` hands the stream to the
/// parent's own descriptor.
///
/// `ToFile` and `AppendToFile` are the structured forms of a shell's `> path`
/// and `>> path`. Both create the file if it is missing; `ToFile` truncates an
/// existing one. A redirected stream is absent from `Output`, where it appears
/// as an empty string.
pub(all) enum Redirect {
  Capture
  Inherit
  ToFile(String)
  AppendToFile(String)
} derive(Debug)

///|
/// How a child is stopped when a run is cancelled.
///
/// Cancellation happens when a timeout expires, when a capture limit is
/// exceeded, or when any stage of a pipeline fails.
///
/// `Kill` ends the child immediately and is the default, because a sandboxed
/// runtime should not have to wait on an untrusted child. `Graceful` first asks
/// the child to stop — `SIGTERM`, or `SIGBREAK` on Windows — and kills it only
/// if it has not exited within `grace_ms`, which is what a child that must
/// flush a file or release a lock needs.
///
/// A graceful teardown delays the cancelling call by up to `grace_ms`: a
/// `timeout_ms` of 20 with `grace_ms` of 1000 raises `TimeoutError` after
/// roughly a second, not after 20 milliseconds.
pub(all) enum Cancel {
  Kill
  Graceful(grace_ms~ : Int)
} derive(Debug)

///|
/// A shell-free process description.
///
/// `program` is an executable name or path. Every element of `arguments` is
/// passed as one literal argument. Shell operators such as `|`, `>`, `&&`,
/// `$()`, and `*` have no special meaning.
///
/// The representation is abstract and a `Cmd` is immutable once built, so a
/// plan that has been inspected or approved is the same plan that runs.
struct Cmd {
  program : String
  arguments : Array[String]
  cwd : String?
  env : Map[String, String]
  inherit_env : Bool
  stdin : Stdin?
  stdout : Redirect
  stderr : Redirect
  cancel : Cancel
  no_console_window : Bool
} derive(Debug)

///|
/// Describe one process.
///
/// Standard input is closed unless `stdin` is given, so a non-interactive run
/// cannot accidentally wait on ambient input. `env` adds to the inherited
/// environment; pass `inherit_env=false` to start from an empty one.
/// `no_console_window` suppresses a console window on Windows and is ignored
/// elsewhere.
///
/// `stdout` and `stderr` default to `Capture`, so `output` collects them.
///
/// `arguments` and `env` are copied, so later changes to the caller's
/// collections do not reach the command.
///
/// # Example
/// ```mbt check
/// test {
///   let cmd = @myshell.Cmd("git", ["status", "--short"], cwd="workspace")
///   inspect(cmd.program(), content="git")
///   debug_inspect(cmd.cwd(), content="Some(\"workspace\")")
/// }
/// ```
pub fn Cmd::Cmd(
  program : String,
  arguments : Array[String],
  cwd? : String,
  env? : Map[String, String] = {},
  inherit_env? : Bool = true,
  stdin? : Stdin,
  stdout? : Redirect = Capture,
  stderr? : Redirect = Capture,
  cancel? : Cancel = Kill,
  no_console_window? : Bool = false,
) -> Cmd {
  {
    program,
    arguments: arguments.copy(),
    cwd,
    env: env.copy(),
    inherit_env,
    stdin,
    stdout,
    stderr,
    cancel,
    no_console_window,
  }
}

///|
/// The executable name or path.
pub fn Cmd::program(self : Cmd) -> String {
  self.program
}

///|
/// The literal argument vector, as a read-only view.
pub fn Cmd::arguments(self : Cmd) -> ArrayView[String] {
  self.arguments[:]
}

///|
/// The configured working directory.
pub fn Cmd::cwd(self : Cmd) -> String? {
  self.cwd
}

///|
/// A copy of the environment entries added for the child.
pub fn Cmd::env(self : Cmd) -> Map[String, String] {
  self.env.copy()
}

///|
/// Whether the child also receives the parent environment.
pub fn Cmd::inherit_env(self : Cmd) -> Bool {
  self.inherit_env
}

///|
/// The configured standard input, if any.
pub fn Cmd::stdin(self : Cmd) -> Stdin? {
  self.stdin
}

///|
/// Where standard output goes.
pub fn Cmd::stdout(self : Cmd) -> Redirect {
  self.stdout
}

///|
/// Where standard error goes.
pub fn Cmd::stderr(self : Cmd) -> Redirect {
  self.stderr
}

///|
/// How the child is stopped when the run is cancelled.
pub fn Cmd::cancel(self : Cmd) -> Cancel {
  self.cancel
}

///|
/// Whether creation of a console window is suppressed on Windows.
pub fn Cmd::no_console_window(self : Cmd) -> Bool {
  self.no_console_window
}

///|
pub extend Cmd with @debug.Debug::{to_repr}

///|
pub extend Stdin with @debug.Debug::{to_repr}

///|
pub extend Redirect with @debug.Debug::{to_repr}

///|
pub extend Cancel with @debug.Debug::{to_repr}
