///|
/// Whether `name` matches the glob `pattern`.
///
/// This is the pattern language a shell uses for filenames, and nothing else:
/// `*` matches any run of characters within one path segment, `?` matches one
/// such character, `[abc]` and `[a-z]` match a character from a set, `[!abc]`
/// and `[^abc]` match one outside it, and `**` as a whole segment matches any
/// number of segments including none. Everything else is literal.
///
/// A `/` is never matched by `*` or `?`, and a leading `.` in a segment is
/// matched only by a literal `.` in the pattern, so `*` does not pick up
/// hidden entries.
///
/// This function only compares strings; nothing is read from disk. Use it to
/// filter names you already have, and `glob` to find names on disk.
///
/// # Example
/// ```mbt check
/// test {
///   assert_true(@myshell.glob_matches("*.mbt", "cmd.mbt"))
///   assert_false(@myshell.glob_matches("*.mbt", "src/cmd.mbt"))
///   assert_true(@myshell.glob_matches("src/**/*.mbt", "src/a/b/cmd.mbt"))
///   assert_false(@myshell.glob_matches("*", ".hidden"))
/// }
/// ```
pub fn glob_matches(pattern : String, name : String) -> Bool {
  match_segments(split_path(pattern)[:], split_path(name)[:])
}

///|
fn split_path(path : String) -> Array[String] {
  let segments = []
  let current = StringBuilder()
  for char in path {
    if char == '/' {
      segments.push(current.to_string())
      current.reset()
    } else {
      current.write_char(char)
    }
  }
  segments.push(current.to_string())
  segments
}

///|
/// Match a pattern's segments against a name's segments.
///
/// `**` is the only segment that can consume more than one, so it is the only
/// place this has to try alternatives.
fn match_segments(
  pattern : ArrayView[String],
  name : ArrayView[String],
) -> Bool {
  match pattern {
    [] => name is []
    ["**", .. rest] =>
      // Consume no segments, or one and try again.
      match_segments(rest, name) ||
      (name is [_, .. tail] && match_segments(pattern, tail))
    [head, .. rest] =>
      name is [first, .. tail] &&
      match_segment(head, first) &&
      match_segments(rest, tail)
  }
}

///|
/// Match one path segment, where `*` and `?` cannot cross a `/`.
fn match_segment(pattern : String, name : String) -> Bool {
  // A leading `.` is only ever matched literally, so `*` skips hidden entries.
  if name.has_prefix(".") && !pattern.has_prefix(".") {
    return false
  }
  let pattern_chars = collect_chars(pattern)
  let name_chars = collect_chars(name)
  match_chars(pattern_chars[:], name_chars[:])
}

///|
fn collect_chars(text : String) -> Array[Char] {
  let chars = []
  for char in text {
    chars.push(char)
  }
  chars
}

///|
/// Backtracking wildcard match over one segment.
fn match_chars(pattern : ArrayView[Char], name : ArrayView[Char]) -> Bool {
  match pattern {
    [] => name is []
    ['*', .. rest] =>
      // Collapse runs of `*` first, so a pattern of many stars cannot make
      // this branch exponentially.
      if rest is ['*', ..] {
        match_chars(rest, name)
      } else {
        match_chars(rest, name) ||
        (name is [_, .. tail] && match_chars(pattern, tail))
      }
    ['?', .. rest] => name is [_, .. tail] && match_chars(rest, tail)
    ['[', .. rest] =>
      match parse_class(rest) {
        None =>
          // An unterminated `[` is a literal, as a shell treats it.
          name is [first, .. tail] && first == '[' && match_chars(rest, tail)
        Some((members, negated, remainder)) =>
          name is [first, .. tail] &&
          in_class(members[:], first) != negated &&
          match_chars(remainder, tail)
      }
    [literal, .. rest] =>
      name is [first, .. tail] && first == literal && match_chars(rest, tail)
  }
}

///|
/// Read a `[...]` class, returning its members, whether it is negated, and
/// what follows it. `None` means the class is never closed.
fn parse_class(
  pattern : ArrayView[Char],
) -> (Array[(Char, Char)], Bool, ArrayView[Char])? {
  let (negated, body) = match pattern {
    ['!', .. rest] | ['^', .. rest] => (true, rest)
    _ => (false, pattern)
  }
  let members = []
  // A `]` in the first position is a literal member, not the terminator.
  let mut rest = match body {
    [']', .. tail] => {
      members.push((']', ']'))
      tail
    }
    _ => body
  }
  for ;; {
    match rest {
      [] => return None
      [']', .. tail] => return Some((members, negated, tail))
      [low, '-', high, .. tail] if high != ']' => {
        members.push((low, high))
        rest = tail
      }
      [single, .. tail] => {
        members.push((single, single))
        rest = tail
      }
    }
  }
}

///|
fn in_class(members : ArrayView[(Char, Char)], candidate : Char) -> Bool {
  for range in members {
    if candidate >= range.0 && candidate <= range.1 {
      return true
    }
  }
  false
}

///|
/// Expand a glob pattern against the filesystem.
///
/// Returns the paths that exist and match, in sorted order, spelled the way
/// the pattern was: relative to `cwd` for a relative pattern, absolute for a
/// pattern starting with `/`. A pattern that matches nothing returns an empty
/// array rather than the pattern itself, which is the one place this differs
/// from a shell's default.
///
/// Directories that cannot be read are skipped rather than failing the whole
/// expansion, so an unreadable corner of a tree does not hide the rest of it.
///
/// See `glob_matches` for the pattern language. This is what replaces letting
/// a shell expand `*.mbt` before a command ever runs — here the expansion is
/// a value you can inspect, and the results reach the child as separate,
/// literal arguments.
///
/// # Example
/// ```mbt check
/// #cfg(not(platform="windows"))
/// async test {
///   let sources = @myshell.glob("*.mbt")
///   assert_true(sources.contains("glob.mbt"))
///   assert_true(sources.contains("execute.mbt"))
/// }
/// ```
pub async fn glob(pattern : String, cwd? : String = ".") -> Array[String] {
  let segments = split_path(pattern)
  let absolute = segments is [first, ..] && first.is_empty()
  //
  // An absolute pattern starts at the root and keeps its leading `/`; a
  // relative one starts at `cwd` and is reported relative to it.
  let (base, prefix, rest) = if absolute {
    ("/", "/", segments[1:])
  } else {
    (cwd, "", segments[:])
  }
  let found = []
  expand(base, prefix, rest, found)
  // `Array::sort` orders strings by length first, so "plain.txt" would come
  // before "od d*name.txt". A shell lists matches in code-unit order, and so
  // does this.
  found.sort_by(compare_code_units)
  found
}

///|
/// Compare two strings by code unit, then by length.
fn compare_code_units(left : String, right : String) -> Int {
  let shared = if left.length() < right.length() {
    left.length()
  } else {
    right.length()
  }
  for index in 0..<shared {
    if left[index] != right[index] {
      return if left[index] < right[index] { -1 } else { 1 }
    }
  }
  left.length() - right.length()
}

///|
/// Walk one pattern segment at a time, reading only the directories a segment
/// actually requires.
///
/// `base` is where to look on disk and `prefix` is how to spell what is found.
/// They differ whenever `cwd` is not the process's own directory, so every
/// filesystem call has to use `base` and every recorded result `prefix`.
async fn expand(
  base : String,
  prefix : String,
  segments : ArrayView[String],
  found : Array[String],
) -> Unit {
  match segments {
    [] => if !prefix.is_empty() && @fs.exists(base) { found.push(prefix) }
    ["", .. rest] =>
      // A doubled or trailing `/` in the pattern carries no meaning.
      expand(base, prefix, rest, found)
    ["**", .. rest] => {
      // Zero segments, then every subdirectory in turn.
      expand(base, prefix, rest, found)
      for entry in read_directory(base) {
        if is_directory(join(base, entry)) {
          expand(join(base, entry), join(prefix, entry), segments, found)
        }
      }
    }
    [segment, .. rest] =>
      if is_literal(segment) {
        // No metacharacters, so there is nothing to search: descend directly
        // and let the final `exists` decide.
        let child = join(base, segment)
        if rest is [] {
          if @fs.exists(child) {
            found.push(join(prefix, segment))
          }
        } else if is_directory(child) {
          expand(child, join(prefix, segment), rest, found)
        }
      } else {
        for entry in read_directory(base) {
          if match_segment(segment, entry) {
            if rest is [] {
              found.push(join(prefix, entry))
            } else if is_directory(join(base, entry)) {
              expand(join(base, entry), join(prefix, entry), rest, found)
            }
          }
        }
      }
  }
}

///|
fn join(prefix : String, entry : String) -> String {
  if prefix.is_empty() || prefix.has_suffix("/") {
    prefix + entry
  } else {
    prefix + "/" + entry
  }
}

///|
fn is_literal(segment : String) -> Bool {
  !segment.contains("*") && !segment.contains("?") && !segment.contains("[")
}

///|
/// List a directory, treating one that cannot be read as empty.
async fn read_directory(path : String) -> Array[String] {
  @fs.readdir(path, include_hidden=true) catch {
    _ => []
  }
}

///|
async fn is_directory(path : String) -> Bool {
  (@fs.kind(path) catch { _ => return false }) is Directory
}
