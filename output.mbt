///|
/// Captured output and exit status from a command or pipeline.
///
/// A single command reports one element in `stage_exit_codes` and one in
/// `stage_stderr`. For a pipeline, `exit_code` uses pipefail semantics: it is
/// the rightmost non-zero stage status, or zero when every stage succeeds, and
/// `stderr` is the concatenation of `stage_stderr` in stage order.
///
/// Text fields use lossy UTF-8 decoding so arbitrary process output cannot
/// cancel a run. `stdout_bytes` and `stage_stderr_bytes` keep the exact bytes.
pub struct Output {
  exit_code : Int
  stage_exit_codes : Array[Int]
  stdout : String
  stdout_bytes : Bytes
  stderr : String
  stage_stderr : Array[String]
  stage_stderr_bytes : Array[Bytes]
} derive(Debug)

///|
/// Whether the command, or every stage of the pipeline, exited with zero.
pub fn Output::success(self : Output) -> Bool {
  self.exit_code == 0
}

///|
/// Raise `CommandFailed` when the output is not successful.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   try @myshell.Cmd("false", []).output().check() catch {
///     @myshell.ProcessError::CommandFailed(failed) =>
///       inspect(failed.exit_code, content="1")
///     _ => fail("unexpected error")
///   } noraise {
///     _ => fail("expected CommandFailed")
///   }
/// }
/// ```
pub fn Output::check(self : Output) -> Output raise ProcessError {
  if self.exit_code != 0 {
    raise CommandFailed(self)
  }
  self
}

///|
/// Errors reported by the process EDSL itself.
///
/// These are raised before or instead of spawning; a non-zero child status is
/// reported through `Output` rather than as an error.
pub(all) suberror ProcessError {
  EmptyProgram
  EmptyPipeline
  InvalidEnvironmentName(String)
  InvalidOutputLimit(Int)
  OutputLimitExceeded(stream~ : String, limit~ : Int)
  NulByte(String)
  StdinOnNonFirstStage(Int)
  RedirectOnNonFinalStage(Int)
  StdoutNotCaptured
  CommandFailed(Output)
} derive(Debug)

///|
pub extend Output with @debug.Debug::{to_repr}

///|
pub extend ProcessError with @debug.Debug::{to_repr}
