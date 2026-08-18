///|
test "the matcher is a shell's filename language and nothing more" {
  // `*` and `?` stay inside one segment.
  assert_true(@myshell.glob_matches("*.mbt", "cmd.mbt"))
  assert_false(@myshell.glob_matches("*.mbt", "cmd.mbti"))
  assert_false(@myshell.glob_matches("*.mbt", "src/cmd.mbt"))
  assert_true(@myshell.glob_matches("src/*.mbt", "src/cmd.mbt"))
  assert_true(@myshell.glob_matches("c?d.mbt", "cmd.mbt"))
  assert_false(@myshell.glob_matches("c?d.mbt", "cd.mbt"))
  assert_false(@myshell.glob_matches("?", "/"))
  // `**` spans segments, including none at all.
  assert_true(@myshell.glob_matches("src/**/*.mbt", "src/cmd.mbt"))
  assert_true(@myshell.glob_matches("src/**/*.mbt", "src/a/b/cmd.mbt"))
  assert_true(@myshell.glob_matches("**", "a/b/c"))
  assert_false(@myshell.glob_matches("src/**/*.mbt", "other/cmd.mbt"))
  // Character classes, ranges, and negation.
  assert_true(@myshell.glob_matches("[abc].mbt", "b.mbt"))
  assert_false(@myshell.glob_matches("[abc].mbt", "d.mbt"))
  assert_true(@myshell.glob_matches("[a-z]*.mbt", "cmd.mbt"))
  assert_false(@myshell.glob_matches("[a-z]*.mbt", "Cmd.mbt"))
  assert_true(@myshell.glob_matches("[!0-9]*", "cmd"))
  assert_false(@myshell.glob_matches("[!0-9]*", "9cmd"))
  assert_true(@myshell.glob_matches("[^0-9]*", "cmd"))
  // A `]` first in the class is a member, and an unclosed `[` is a literal.
  assert_true(@myshell.glob_matches("[]a]", "]"))
  assert_true(@myshell.glob_matches("[abc", "[abc"))
  // A leading dot is only ever matched literally.
  assert_false(@myshell.glob_matches("*", ".hidden"))
  assert_false(@myshell.glob_matches("?hidden", ".hidden"))
  assert_true(@myshell.glob_matches(".*", ".hidden"))
  assert_false(@myshell.glob_matches("src/*", "src/.hidden"))
  assert_true(@myshell.glob_matches("src/.*", "src/.hidden"))
  // Everything else is literal, including shell operators.
  assert_true(@myshell.glob_matches("a b.mbt", "a b.mbt"))
  assert_true(@myshell.glob_matches("$(echo x)", "$(echo x)"))
}

///|
#cfg(not(platform="windows"))
async test "expansion finds what is on disk and nothing else" {
  let root = @myshell.Cmd("mktemp", ["-d"]).output().check().stdout
    .trim()
    .to_owned()
  for
    path in [
      "a.mbt", "b.mbt", "c.txt", ".hidden.mbt", "src/d.mbt", "src/e.txt", "src/deep/f.mbt",
      "src/deep/g.txt",
    ] {
    @myshell.Cmd("mkdir", ["-p", "\{root}/\{path}/.."]).status() |> ignore
    @myshell.Cmd("touch", ["\{root}/\{path}"]).status() |> ignore
  }
  // One segment, and hidden entries stay hidden.
  assert_eq(@myshell.glob("*.mbt", cwd=root), ["a.mbt", "b.mbt"])
  assert_eq(@myshell.glob(".*.mbt", cwd=root), [".hidden.mbt"])
  // A literal segment needs no search.
  assert_eq(@myshell.glob("src/d.mbt", cwd=root), ["src/d.mbt"])
  assert_eq(@myshell.glob("src/*.txt", cwd=root), ["src/e.txt"])
  // `**` spans any number of directories, including none.
  assert_eq(@myshell.glob("**/*.mbt", cwd=root), [
    "a.mbt", "b.mbt", "src/d.mbt", "src/deep/f.mbt",
  ])
  // Results are sorted, and a pattern matching nothing yields nothing.
  assert_eq(@myshell.glob("*.rs", cwd=root), [])
  assert_eq(@myshell.glob("nope/*.mbt", cwd=root), [])
  // An absolute pattern keeps its leading slash.
  assert_eq(@myshell.glob("\{root}/*.txt"), ["\{root}/c.txt"])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "an expansion feeds a command as separate literal arguments" {
  let root = @myshell.Cmd("mktemp", ["-d"]).output().check().stdout
    .trim()
    .to_owned()
  // A filename containing a space and a glob character: a shell would have to
  // be quoted carefully here, and expansion here cannot re-split it.
  @myshell.Cmd("touch", ["\{root}/od d*name.txt"]).status() |> ignore
  @myshell.Cmd("touch", ["\{root}/plain.txt"]).status() |> ignore
  let matched = @myshell.glob("*.txt", cwd=root)
  assert_eq(matched, ["od d*name.txt", "plain.txt"])
  // Hand them to a command; each stays one argument.
  let output = @myshell.Cmd("ls", matched, cwd=root).output().check()
  assert_eq(output.stdout.split("\n").filter(l => !l.is_empty()).length(), 2)
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "matches come back in code-unit order, not by length" {
  let root = @myshell.Cmd("mktemp", ["-d"]).output().check().stdout
    .trim()
    .to_owned()
  // No case differences here: macOS is case-insensitive by default, so
  // "B.txt" and "b.txt" would be one file there and two on Linux.
  for name in ["b.txt", "ab.txt", "aaa.txt"] {
    @myshell.Cmd("touch", ["\{root}/\{name}"]).status() |> ignore
  }
  // `Array::sort` on strings orders by length first, which would have put
  // "b.txt" before "aaa.txt". A shell does not, and neither does this.
  assert_eq(@myshell.glob("*.txt", cwd=root), ["aaa.txt", "ab.txt", "b.txt"])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}
