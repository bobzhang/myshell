///|
/// White-box tests for the path parser.
///
/// The parser takes the platform as an argument rather than reading it from
/// the build, so Windows syntax can be checked from a Unix machine — which is
/// the only way this gets tested at all, since every filesystem test in the
/// suite is skipped on Windows.
fn parsed(
  text : String,
  windows~ : Bool,
  escapes? : Bool = true,
) -> (String, Array[String], Bool) {
  let (root, segments, directories_only) = parse_path(text, windows~, escapes~)
  let shown = match root {
    Relative => ""
    Rooted(root) => root
    // Shown with a trailing marker so the two drive forms are visibly
    // different in these expectations.
    DriveRelative(root) => root + "|drive-relative"
  }
  (shown, segments, directories_only)
}

///|
test "unix paths" {
  debug_inspect(
    parsed("a/b.mbt", windows=false),
    content=(
      #|("", ["a", "b.mbt"], false)
    ),
  )
  debug_inspect(
    parsed("/a/b.mbt", windows=false),
    content=(
      #|("/", ["a", "b.mbt"], false)
    ),
  )
  // Redundant separators collapse; a trailing one asks for directories.
  debug_inspect(
    parsed("a//b", windows=false),
    content=(
      #|("", ["a", "b"], false)
    ),
  )
  debug_inspect(
    parsed("a/b/", windows=false),
    content=(
      #|("", ["a", "b"], true)
    ),
  )
  // A path that is only separators is its root, with nothing else asked for.
  debug_inspect(
    parsed("/", windows=false),
    content=(
      #|("/", [], false)
    ),
  )
  debug_inspect(
    parsed("//", windows=false),
    content=(
      #|("/", [], false)
    ),
  )
  // An empty path is not the root.
  debug_inspect(
    parsed("", windows=false),
    content=(
      #|("", [], false)
    ),
  )
  // On Unix a backslash escapes, and an escaped separator still separates.
  debug_inspect(
    parsed("a\\/b", windows=false),
    content=(
      #|("", ["a", "b"], false)
    ),
  )
  debug_inspect(
    parsed("\\/tmp/x", windows=false),
    content=(
      #|("/", ["tmp", "x"], false)
    ),
  )
  debug_inspect(
    parsed("a\\*b", windows=false),
    content=(
      #|("", ["a\\*b"], false)
    ),
  )
  // A candidate name carries no pattern syntax: its backslash is a character.
  debug_inspect(
    parsed("a\\b", windows=false, escapes=false),
    content=(
      #|("", ["a\\b"], false)
    ),
  )
}

///|
test "windows paths" {
  // A drive is a root, whichever separator follows it.
  debug_inspect(
    parsed("C:/Windows/*", windows=true),
    content=(
      #|("C:/", ["Windows", "*"], false)
    ),
  )
  debug_inspect(
    parsed("C:\\Windows\\*", windows=true),
    content=(
      #|("C:/", ["Windows", "*"], false)
    ),
  )
  debug_inspect(
    parsed("c:/x", windows=true),
    content=(
      #|("c:/", ["x"], false)
    ),
  )
  // A bare drive is relative to that drive's own working directory.
  debug_inspect(
    parsed("C:x/y", windows=true),
    content=(
      #|("C:|drive-relative", ["x", "y"], false)
    ),
  )
  // A share is part of the root, not a pair of segments.
  debug_inspect(
    parsed("\\\\server\\share\\dir\\*", windows=true),
    content=(
      #|("//server/share/", ["dir", "*"], false)
    ),
  )
  debug_inspect(
    parsed("//server/share/dir", windows=true),
    content=(
      #|("//server/share/", ["dir"], false)
    ),
  )
  // A bare separator is rooted on the current drive.
  debug_inspect(
    parsed("\\Windows", windows=true),
    content=(
      #|("/", ["Windows"], false)
    ),
  )
  // Relative paths still work, and a backslash is a separator rather than an
  // escape, so it cannot smuggle a metacharacter through as a literal.
  debug_inspect(
    parsed("src\\*.mbt", windows=true),
    content=(
      #|("", ["src", "*.mbt"], false)
    ),
  )
  debug_inspect(
    parsed("a\\b\\", windows=true),
    content=(
      #|("", ["a", "b"], true)
    ),
  )
}

///|
test "incomplete windows roots are not roots" {
  // A share needs a server and a share name; half of one is not a root.
  debug_inspect(
    parsed("\\\\server", windows=true),
    content=(
      #|("/", ["server"], false)
    ),
  )
  // The trailing separator still asks for directories only.
  debug_inspect(
    parsed("\\\\server\\", windows=true),
    content=(
      #|("/", ["server"], true)
    ),
  )
  // A drive letter is one letter followed by a colon, nothing else.
  debug_inspect(
    parsed("ab:/x", windows=true),
    content=(
      #|("", ["ab:", "x"], false)
    ),
  )
}
