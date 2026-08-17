///|
/// A non-empty sequence of commands connected by operating-system pipes.
pub struct Pipeline {
  commands_ : Array[Cmd]
} derive(Debug)

///|
/// Create a pipeline from `commands`.
///
/// An empty pipeline is rejected when it is executed.
pub fn Pipeline::new(commands : Array[Cmd]) -> Pipeline {
  { commands_: commands.copy() }
}

///|
/// Return a copy with `command` appended as the next stage.
pub fn Pipeline::pipe(self : Pipeline, command : Cmd) -> Pipeline {
  let commands = self.commands_.copy()
  commands.push(command)
  { commands_: commands }
}

///|
/// Return the commands in execution order.
pub fn Pipeline::commands(self : Pipeline) -> Array[Cmd] {
  self.commands_.copy()
}
