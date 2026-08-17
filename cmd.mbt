///|
/// A shell-free process description.
///
/// `program` is an executable name or path. Every element of `arguments` is
/// passed as one literal argument. Shell operators such as `|`, `>`, `&&`,
/// `$()`, and `*` have no special meaning.
struct Cmd {
  program_ : String
  arguments_ : Array[String]
  cwd_ : String?
  environment_ : Map[String, String]
  inherit_environment_ : Bool
  stdin_text_ : String?
  stdin_bytes_ : Bytes?
  no_console_window_ : Bool
} derive(Debug)

///|
/// Create a process description from an executable and its literal arguments.
///
/// # Example
/// ```mbt check
/// test {
///   let cmd = Cmd::Cmd("git", ["status", "--short"])
///   inspect(cmd.program(), content="git")
///   debug_inspect(cmd.arguments(), content="[\"status\", \"--short\"]")
/// }
/// ```
#alias(new, deprecated="Use Cmd::Cmd instead")
pub fn Cmd::Cmd(program : String, arguments : Array[String]) -> Cmd {
  {
    program_: program,
    arguments_: arguments.copy(),
    cwd_: None,
    environment_: {},
    inherit_environment_: true,
    stdin_text_: None,
    stdin_bytes_: None,
    no_console_window_: false,
  }
}

///|
/// Return a copy with one literal argument appended.
pub fn Cmd::arg(self : Cmd, argument : String) -> Cmd {
  let arguments = self.arguments_.copy()
  arguments.push(argument)
  {
    program_: self.program_,
    arguments_: arguments,
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy with literal arguments appended.
pub fn Cmd::args(self : Cmd, arguments : ArrayView[String]) -> Cmd {
  let all_arguments = self.arguments_.copy()
  for argument in arguments {
    all_arguments.push(argument)
  }
  {
    program_: self.program_,
    arguments_: all_arguments,
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy that runs in `directory`.
pub fn Cmd::cwd(self : Cmd, directory : String) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: Some(directory),
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy with one environment variable set for the child process.
pub fn Cmd::env(self : Cmd, name : String, value : String) -> Cmd {
  let environment = self.environment_.copy()
  environment[name] = value
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: environment,
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy with all entries in `environment` set for the child process.
pub fn Cmd::envs(self : Cmd, environment : Map[String, String]) -> Cmd {
  let all_environment = self.environment_.copy()
  all_environment.merge_in_place(environment)
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: all_environment,
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy that does not inherit the parent environment.
///
/// Variables added with `env` or `envs` are still supplied.
pub fn Cmd::clear_env(self : Cmd) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: false,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy that receives `input` on standard input.
pub fn Cmd::stdin(self : Cmd, input : String) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: Some(input),
    stdin_bytes_: None,
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy that receives arbitrary bytes on standard input.
///
/// Calling `stdin` or `stdin_bytes` replaces any previously configured input.
pub fn Cmd::stdin_bytes(self : Cmd, input : Bytes) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: None,
    stdin_bytes_: Some(input),
    no_console_window_: self.no_console_window_,
  }
}

///|
/// Return a copy with creation of a console window disabled on Windows.
///
/// This option has no effect on other platforms.
pub fn Cmd::no_console_window(self : Cmd) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: true,
  }
}

///|
/// Start a two-command pipeline.
pub fn Cmd::pipe(self : Cmd, next : Cmd) -> Pipeline {
  Pipeline([self, next])
}

///|
/// Return the executable name or path.
pub fn Cmd::program(self : Cmd) -> String {
  self.program_
}

///|
/// Return the literal argument vector.
pub fn Cmd::arguments(self : Cmd) -> Array[String] {
  self.arguments_.copy()
}

///|
/// Return the configured working directory.
pub fn Cmd::working_directory(self : Cmd) -> String? {
  self.cwd_
}

///|
/// Return a copy of the configured environment additions.
pub fn Cmd::environment(self : Cmd) -> Map[String, String] {
  self.environment_.copy()
}

///|
/// Whether the child inherits the parent environment.
pub fn Cmd::inherits_environment(self : Cmd) -> Bool {
  self.inherit_environment_
}

///|
/// Return the configured standard input text, if any.
pub fn Cmd::standard_input(self : Cmd) -> String? {
  self.stdin_text_
}

///|
/// Return the configured standard input bytes, if `stdin_bytes` was used.
pub fn Cmd::standard_input_bytes(self : Cmd) -> Bytes? {
  self.stdin_bytes_
}

///|
/// Make a deep snapshot for execution.
///
/// `Array` and `Map` are mutable reference types, so copying every collection
/// here prevents a plan from changing after validation once async work begins.
fn Cmd::snapshot(self : Cmd) -> Cmd {
  {
    program_: self.program_,
    arguments_: self.arguments_.copy(),
    cwd_: self.cwd_,
    environment_: self.environment_.copy(),
    inherit_environment_: self.inherit_environment_,
    stdin_text_: self.stdin_text_,
    stdin_bytes_: self.stdin_bytes_,
    no_console_window_: self.no_console_window_,
  }
}
