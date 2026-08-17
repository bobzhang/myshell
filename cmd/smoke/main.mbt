///|
async fn main {
  let output = @myshell.Pipeline::Pipeline([
    @myshell.Cmd::Cmd("/usr/bin/printf", ["sandbox\nworks\n"]).clear_env(),
    @myshell.Cmd::Cmd("/usr/bin/grep", ["works"]).clear_env(),
    @myshell.Cmd::Cmd("/usr/bin/tr", ["a-z", "A-Z"]).clear_env(),
  ]).output()
  output.check() |> ignore
  println(output.stdout.trim())
}
