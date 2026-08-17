///|
async fn main {
  let output = @myshell.Process::pipeline(
    @myshell.Pipeline::new([
      @myshell.Cmd::new("printf", ["sandbox\nworks\n"]),
      @myshell.Cmd::new("grep", ["works"]),
      @myshell.Cmd::new("tr", ["a-z", "A-Z"]),
    ]),
  )
  output.check() |> ignore
  println(output.stdout.trim())
}
