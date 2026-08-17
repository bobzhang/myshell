///|
/// Data written to a child process's standard input.
///
/// `Text` is encoded as UTF-8. `Binary` is written verbatim, which is what a
/// child expecting a compressed or otherwise non-textual stream needs.
pub(all) enum Stdin {
  Text(String)
  Binary(Bytes)
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
  no_console_window? : Bool = false,
) -> Cmd {
  {
    program,
    arguments: arguments.copy(),
    cwd,
    env: env.copy(),
    inherit_env,
    stdin,
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
/// Whether creation of a console window is suppressed on Windows.
pub fn Cmd::no_console_window(self : Cmd) -> Bool {
  self.no_console_window
}

///|
pub extend Cmd with @debug.Debug::{to_repr}

///|
pub extend Stdin with @debug.Debug::{to_repr}
