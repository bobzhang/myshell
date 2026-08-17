///|
/// A sequence of commands connected by operating-system pipes.
///
/// An empty pipeline is rejected when execution is requested.
struct Pipeline {
  commands_ : Array[Cmd]
} derive(Debug)

///|
/// Create a pipeline from `commands`.
///
/// An empty pipeline is rejected when it is executed.
#alias(new, deprecated="Use Pipeline::Pipeline instead")
pub fn Pipeline::Pipeline(commands : Array[Cmd]) -> Pipeline {
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

///|
fn Pipeline::snapshot(self : Pipeline) -> Pipeline {
  { commands_: [ for command in self.commands_ => command.snapshot() ] }
}
