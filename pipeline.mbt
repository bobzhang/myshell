///|
/// A sequence of commands connected by operating-system pipes.
///
/// Every stage is separately visible to the process host, and an empty
/// pipeline is rejected when execution is requested.
struct Pipeline {
  commands : Array[Cmd]
} derive(Debug)

///|
/// Describe a pipeline whose stages are connected by real pipes.
///
/// Only the first stage may carry `stdin`; the rest read from the previous
/// stage. `commands` is copied, so later changes to the caller's array do not
/// reach the pipeline.
///
/// # Example
/// ```mbt check
/// test {
///   let plan = @myshell.Pipeline([
///     Cmd("printf", ["alpha\nbeta\n"]),
///     Cmd("grep", ["beta"]),
///   ])
///   inspect(plan.commands().length(), content="2")
/// }
/// ```
pub fn Pipeline::Pipeline(commands : Array[Cmd]) -> Pipeline {
  { commands: commands.copy() }
}

///|
/// The stages in execution order, as a read-only view.
pub fn Pipeline::commands(self : Pipeline) -> ArrayView[Cmd] {
  self.commands[:]
}

///|
pub extend Pipeline with @debug.Debug::{to_repr}
