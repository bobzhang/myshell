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
  // Character classes, ranges, and negation.
  assert_true(@myshell.glob_matches("[abc].mbt", "b.mbt"))
  assert_false(@myshell.glob_matches("[abc].mbt", "d.mbt"))
  assert_true(@myshell.glob_matches("[a-z]*.mbt", "cmd.mbt"))
  assert_false(@myshell.glob_matches("[a-z]*.mbt", "Cmd.mbt"))
  assert_true(@myshell.glob_matches("[!0-9]*", "cmd"))
  assert_false(@myshell.glob_matches("[!0-9]*", "9cmd"))
  assert_true(@myshell.glob_matches("[^0-9]*", "cmd"))
  // A `]` first in the class is a member; an unclosed `[` is a literal; a
  // reversed range matches nothing.
  assert_true(@myshell.glob_matches("[]a]", "]"))
  assert_true(@myshell.glob_matches("[abc", "[abc"))
  assert_false(@myshell.glob_matches("[z-a]", "b"))
  // A backslash makes the next character literal.
  assert_true(@myshell.glob_matches("\\*", "*"))
  assert_false(@myshell.glob_matches("\\*", "anything"))
  assert_true(@myshell.glob_matches("a\\?c", "a?c"))
  assert_false(@myshell.glob_matches("a\\?c", "abc"))
  assert_true(@myshell.glob_matches("\\[abc]", "[abc]"))
  // Everything else is literal, including shell operators.
  assert_true(@myshell.glob_matches("a b.mbt", "a b.mbt"))
  assert_true(@myshell.glob_matches("$(echo x)", "$(echo x)"))
}

///|
test "globstar spans segments, including none, and skips hidden ones" {
  assert_true(@myshell.glob_matches("src/**/*.mbt", "src/cmd.mbt"))
  assert_true(@myshell.glob_matches("src/**/*.mbt", "src/a/b/cmd.mbt"))
  assert_true(@myshell.glob_matches("**", "a/b/c"))
  assert_true(@myshell.glob_matches("**", "file"))
  assert_true(@myshell.glob_matches("**/x", "x"))
  assert_true(@myshell.glob_matches("**/x", "a/b/x"))
  assert_false(@myshell.glob_matches("src/**/*.mbt", "other/cmd.mbt"))
  // Adjacent globstars are not an error and do not change the meaning.
  assert_true(@myshell.glob_matches("**/**/x", "a/x"))
  assert_true(@myshell.glob_matches("**/**/x", "x"))
  // Hidden segments are out of reach of `**`, as they are of `*`.
  assert_false(@myshell.glob_matches("**", ".git"))
  assert_false(@myshell.glob_matches("**/*.mbt", ".git/cmd.mbt"))
  assert_true(@myshell.glob_matches(".*/**", ".git/objects"))
}

///|
test "a pathological pattern does not take exponential time" {
  // The classic blow-up for a naive matcher: many stars separated by a
  // character that keeps forcing it to try another split.
  let pattern = "*a*a*a*a*a*a*a*a*a*a*a*a*b"
  let name = "a".repeat(200)
  assert_false(@myshell.glob_matches(pattern, name))
  assert_true(@myshell.glob_matches(pattern, name + "b"))
}

///|
/// Build a tree of real files and real directories.
///
/// Note the shape: `mkdir -p "<root>/a.mbt/.."` would create `a.mbt` itself as
/// a directory, and `touch` on a directory then succeeds, so a fixture built
/// that way silently tests nothing about files.
#cfg(not(platform="windows"))
async fn make_tree(root : String, files : Array[String]) -> Unit {
  for file in files {
    let cut = file.rev_find("/")
    if cut is Some(index) {
      @myshell.Cmd("mkdir", ["-p", "\{root}/\{file[:index].to_owned()}"]).status()
      |> ignore
    }
    @myshell.Cmd("touch", ["\{root}/\{file}"]).status() |> ignore
  }
}

///|
#cfg(not(platform="windows"))
async fn temp_dir() -> String {
  @myshell.Cmd("mktemp", ["-d"]).output().check().stdout.trim().to_owned()
}

///|
#cfg(not(platform="windows"))
async test "expansion finds what is on disk and nothing else" {
  let root = temp_dir()
  make_tree(root, [
    "a.mbt", "b.mbt", "c.txt", ".hidden.mbt", "src/d.mbt", "src/e.txt", "src/deep/f.mbt",
  ])
  // Real files, not directories — the thing the old fixture got wrong.
  assert_eq(@myshell.Cmd("test", ["-f", "\{root}/a.mbt"]).status(), 0)
  assert_eq(@myshell.Cmd("test", ["-d", "\{root}/src"]).status(), 0)
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
  // A terminal `**` yields files as well as directories, and never repeats a
  // path even when two globstars could both reach it.
  assert_eq(@myshell.glob("**", cwd=root), [
    "a.mbt", "b.mbt", "c.txt", "src", "src/d.mbt", "src/deep", "src/deep/f.mbt",
    "src/e.txt",
  ])
  assert_eq(@myshell.glob("**/**/f.mbt", cwd=root), ["src/deep/f.mbt"])
  // A trailing slash asks for directories only, and is kept.
  assert_eq(@myshell.glob("*/", cwd=root), ["src/"])
  // Nothing matched is an empty result, not the pattern.
  assert_eq(@myshell.glob("*.rs", cwd=root), [])
  assert_eq(@myshell.glob("nope/*.mbt", cwd=root), [])
  // An absolute pattern keeps its leading slash.
  assert_eq(@myshell.glob("\{root}/*.txt"), ["\{root}/c.txt"])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "a symlink loop does not trap the walker" {
  let root = temp_dir()
  make_tree(root, ["deep/inner/target.mbt"])
  // A link pointing back at an ancestor: following it would never terminate.
  assert_eq(
    @myshell.Cmd("ln", ["-s", "\{root}", "\{root}/deep/loop"]).status(),
    0,
  )
  // Without this the tree alone would satisfy the assertion below, and the
  // test would pass on a system where the link was never created.
  assert_eq(@myshell.Cmd("test", ["-L", "\{root}/deep/loop"]).status(), 0)
  assert_eq(@myshell.glob("**/*.mbt", cwd=root), ["deep/inner/target.mbt"])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "matches come back in code-unit order, not by length" {
  let root = temp_dir()
  // No case differences here: macOS is case-insensitive by default, so
  // "B.txt" and "b.txt" would be one file there and two on Linux.
  make_tree(root, ["b.txt", "ab.txt", "aaa.txt"])
  // `Array::sort` on strings orders by length first, which would have put
  // "b.txt" first. A shell does not, and neither does this.
  assert_eq(@myshell.glob("*.txt", cwd=root), ["aaa.txt", "ab.txt", "b.txt"])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "an expansion feeds a command as separate literal arguments" {
  let root = temp_dir()
  // A filename containing a space and a glob character: a shell would need
  // careful quoting, and an expansion here cannot be re-split or re-expanded.
  make_tree(root, ["od d*name.txt", "plain.txt"])
  let matched = @myshell.glob("*.txt", cwd=root)
  assert_eq(matched, ["od d*name.txt", "plain.txt"])
  let output = @myshell.Cmd("ls", matched, cwd=root).output().check()
  assert_eq(output.stdout.split("\n").filter(l => !l.is_empty()).length(), 2)
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
test "escapes survive splitting and character classes" {
  // An escaped separator is still a separator, as a shell resolves it.
  assert_true(
    @myshell.glob_matches("cmd\\/smoke/main.mbt", "cmd/smoke/main.mbt"),
  )
  // Inside a class, a backslash makes the next character a plain member, so
  // this is the three characters and not the range `a` to `c`.
  assert_true(@myshell.glob_matches("[a\\-c]", "-"))
  assert_true(@myshell.glob_matches("[a\\-c]", "a"))
  assert_true(@myshell.glob_matches("[a\\-c]", "c"))
  assert_false(@myshell.glob_matches("[a\\-c]", "b"))
  // An unescaped range still behaves as one.
  assert_true(@myshell.glob_matches("[a-c]", "b"))
  assert_true(@myshell.glob_matches("[\\]]", "]"))
}

///|
#cfg(not(platform="windows"))
async test "adjacent globstars do not explode on a deep tree" {
  let root = temp_dir()
  // Twenty nested directories. Exploring every way of splitting this path
  // between the globstars would be combinatorial; visiting each place in the
  // tree once per place in the pattern is not.
  let deep = "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a"
  make_tree(root, ["\{deep}/target.mbt"])
  assert_eq(@myshell.glob("**/**/**/**/target.mbt", cwd=root), [
    "\{deep}/target.mbt",
  ])
  // The same pattern for a name that is not there has to finish too.
  assert_eq(@myshell.glob("**/**/**/**/missing.mbt", cwd=root), [])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "a dangling or self-referential link still matches" {
  let root = temp_dir()
  make_tree(root, ["real.txt"])
  assert_eq(
    @myshell.Cmd("ln", ["-s", "nowhere.txt", "\{root}/dangling.txt"]).status(),
    0,
  )
  assert_eq(
    @myshell.Cmd("ln", ["-s", "self.txt", "\{root}/self.txt"]).status(),
    0,
  )
  // A glob matches the directory entry, so a link that resolves to nothing is
  // still a match, and one that points at itself must not raise `ELOOP`.
  assert_eq(@myshell.glob("*.txt", cwd=root), [
    "dangling.txt", "real.txt", "self.txt",
  ])
  @myshell.Cmd("rm", ["-rf", root]).status() |> ignore
}

///|
#cfg(not(platform="windows"))
async test "a pattern of only separators is the root" {
  assert_eq(@myshell.glob("/"), ["/"])
  assert_eq(@myshell.glob("//"), ["/"])
  assert_eq(@myshell.glob("///"), ["/"])
}
