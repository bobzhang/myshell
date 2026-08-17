///|
async fn main {
  let output = @myshell.Pipeline([
    @myshell.Cmd("/usr/bin/printf", ["sandbox\nworks\n"], inherit_env=false),
    @myshell.Cmd("/usr/bin/grep", ["works"], inherit_env=false),
    @myshell.Cmd("/usr/bin/tr", ["a-z", "A-Z"], inherit_env=false),
  ]).output()
  output.check() |> ignore
  println(output.stdout.trim())
}
