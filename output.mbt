///|
/// Captured output and exit status from a command or pipeline.
///
/// For a pipeline, `exit_code` uses pipefail semantics: it is the rightmost
/// non-zero stage status, or zero when every stage succeeds. `stderr` is the
/// concatenation of `stage_stderr` in stage order.
pub struct Output {
  exit_code : Int
  stage_exit_codes : Array[Int]
  stdout_bytes : Bytes
  stdout : String
  stderr_bytes : Bytes
  stderr : String
  stage_stderr_bytes : Array[Bytes]
  stage_stderr : Array[String]
} derive(Debug)

///|
/// Whether the command, or every stage of the pipeline, exited with zero.
pub fn Output::success(self : Output) -> Bool {
  self.exit_code == 0
}

///|
/// Raise `CommandFailed` when the output is not successful.
pub fn Output::check(self : Output) -> Output raise ProcessError {
  if self.exit_code != 0 {
    raise CommandFailed(self)
  }
  self
}

///|
/// Errors reported by the process EDSL itself.
pub(all) suberror ProcessError {
  EmptyProgram
  EmptyPipeline
  InvalidEnvironmentName(String)
  InvalidOutputLimit(Int)
  OutputLimitExceeded(stream~ : String, limit~ : Int)
  NulByte(String)
  StdinOnNonFirstStage(Int)
  CommandFailed(Output)
} derive(Debug)
