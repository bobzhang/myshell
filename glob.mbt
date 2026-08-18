///|
/// One element of a single path segment's pattern.
priv enum Item {
  Literal(Char)
  Any
  Star
  Class(Array[(Char, Char)], Bool)
}

///|
/// Whether `name` matches the glob `pattern`.
///
/// This is the pattern language a shell uses for filenames, and nothing else:
/// `*` matches any run of characters within one path segment, `?` matches one
/// such character, `[abc]` and `[a-z]` match a character from a set, `[!abc]`
/// and `[^abc]` match one outside it, and `**` as a whole segment matches any
/// number of segments including none. A backslash makes the next character
/// literal. Everything else is literal already.
///
/// A `/` is never matched by `*` or `?`, and a segment starting with `.` is
/// matched only by a pattern starting with a literal `.`. That rule applies to
/// `**` too, so neither `*` nor `**` reaches hidden entries.
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
///   assert_true(@myshell.glob_matches("\\*", "*"))
/// }
/// ```
pub fn glob_matches(pattern : String, name : String) -> Bool {
  match_segments(split_path(pattern), split_path(name))
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
/// Whether a directory entry is hidden from `*` and `**`.
fn is_hidden(name : String) -> Bool {
  name.has_prefix(".")
}

///|
/// Match a pattern's segments against a name's segments.
///
/// `**` is the only segment that can consume more than one, so it is the only
/// place alternatives arise. This walks them with a single backtrack point
/// rather than recursing, so a pattern with many `**` cannot blow up: each
/// mismatch resumes from the most recent `**` and advances it by one segment.
fn match_segments(pattern : Array[String], name : Array[String]) -> Bool {
  let mut pattern_index = 0
  let mut name_index = 0
  let mut star = -1
  let mut retry_at = 0
  for ;; {
    if name_index < name.length() &&
      pattern_index < pattern.length() &&
      pattern[pattern_index] != "**" &&
      match_segment(pattern[pattern_index], name[name_index]) {
      pattern_index = pattern_index + 1
      name_index = name_index + 1
    } else if pattern_index < pattern.length() && pattern[pattern_index] == "**" {
      star = pattern_index
      retry_at = name_index
      pattern_index = pattern_index + 1
    } else if star >= 0 &&
      retry_at < name.length() &&
      // `**` never reaches a hidden segment either.
      !is_hidden(name[retry_at]) {
      retry_at = retry_at + 1
      name_index = retry_at
      pattern_index = star + 1
    } else {
      break
    }
    if name_index >= name.length() && pattern_index >= pattern.length() {
      return true
    }
  }
  // Trailing `**` may match nothing at all.
  while pattern_index < pattern.length() && pattern[pattern_index] == "**" {
    pattern_index = pattern_index + 1
  }
  pattern_index >= pattern.length() && name_index >= name.length()
}

///|
/// Match one path segment, where `*` and `?` cannot cross a `/`.
fn match_segment(pattern : String, name : String) -> Bool {
  let items = parse_segment(pattern)
  // A leading `.` is only ever matched literally, so `*` skips hidden entries.
  if is_hidden(name) && !(items is [Literal('.'), ..]) {
    return false
  }
  match_items(items, collect_chars(name))
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
/// Parse one segment into its elements, resolving escapes and classes once.
fn parse_segment(pattern : String) -> Array[Item] {
  let chars = collect_chars(pattern)
  let items = []
  let mut index = 0
  while index < chars.length() {
    match chars[index] {
      '\\' =>
        if index + 1 < chars.length() {
          items.push(Literal(chars[index + 1]))
          index = index + 2
        } else {
          // A trailing backslash is itself.
          items.push(Literal('\\'))
          index = index + 1
        }
      '?' => {
        items.push(Any)
        index = index + 1
      }
      '*' => {
        // Collapse runs, so `***` costs no more than `*`.
        if !(items is [.., Star]) {
          items.push(Star)
        }
        index = index + 1
      }
      '[' =>
        match parse_class(chars, index + 1) {
          Some((members, negated, next)) => {
            items.push(Class(members, negated))
            index = next
          }
          // An unterminated `[` is a literal, as a shell treats it.
          None => {
            items.push(Literal('['))
            index = index + 1
          }
        }
      char => {
        items.push(Literal(char))
        index = index + 1
      }
    }
  }
  items
}

///|
/// Read a `[...]` class starting just past the `[`, returning its members,
/// whether it is negated, and the index after the closing `]`.
fn parse_class(
  chars : Array[Char],
  start : Int,
) -> (Array[(Char, Char)], Bool, Int)? {
  let mut index = start
  let negated = index < chars.length() &&
    (chars[index] == '!' || chars[index] == '^')
  if negated {
    index = index + 1
  }
  let members = []
  // A `]` in the first position is a literal member, not the terminator.
  if index < chars.length() && chars[index] == ']' {
    members.push((']', ']'))
    index = index + 1
  }
  while index < chars.length() {
    if chars[index] == ']' {
      return Some((members, negated, index + 1))
    }
    if index + 2 < chars.length() &&
      chars[index + 1] == '-' &&
      chars[index + 2] != ']' {
      let low = chars[index]
      let high = chars[index + 2]
      // A reversed range such as `[z-a]` matches nothing, as in a shell.
      if low <= high {
        members.push((low, high))
      }
      index = index + 3
    } else {
      members.push((chars[index], chars[index]))
      index = index + 1
    }
  }
  None
}

///|
/// Match a parsed segment against a name.
///
/// Iterative with one backtrack point, so `*a*a*…` against a long name stays
/// quadratic in the worst case rather than exponential, and nothing recurses.
fn match_items(items : Array[Item], name : Array[Char]) -> Bool {
  let mut item_index = 0
  let mut name_index = 0
  let mut star = -1
  let mut retry_at = 0
  while name_index < name.length() {
    if item_index < items.length() &&
      item_matches(items[item_index], name[name_index]) {
      item_index = item_index + 1
      name_index = name_index + 1
    } else if item_index < items.length() && items[item_index] is Star {
      star = item_index
      retry_at = name_index
      item_index = item_index + 1
    } else if star >= 0 {
      retry_at = retry_at + 1
      name_index = retry_at
      item_index = star + 1
    } else {
      return false
    }
  }
  while item_index < items.length() && items[item_index] is Star {
    item_index = item_index + 1
  }
  item_index >= items.length()
}

///|
fn item_matches(item : Item, candidate : Char) -> Bool {
  match item {
    Literal(char) => char == candidate
    Any => true
    Star => false
    Class(members, negated) => {
      let mut found = false
      for range in members {
        if candidate >= range.0 && candidate <= range.1 {
          found = true
          break
        }
      }
      found != negated
    }
  }
}

///|
/// Expand a glob pattern against the filesystem.
///
/// Returns the paths that exist and match, in code-unit order, relative to
/// `cwd` for a relative pattern and absolute for a pattern starting with `/`.
/// Redundant separators are collapsed, and a trailing `/` is kept and restricts
/// the result to directories, as a shell does. A pattern that matches nothing
/// returns an empty array rather than the pattern itself, which is the one
/// place this deliberately differs from a shell.
///
/// Hidden entries are reached only by a pattern with a literal leading `.`,
/// and `.` and `..` are never produced. Symbolic links to directories are not
/// descended by `**`, which is what keeps a link pointing at an ancestor from
/// looping forever. A directory that cannot be read is skipped rather than
/// failing the whole expansion.
///
/// See `glob_matches` for the pattern language. This is what replaces letting
/// a shell expand `*.mbt` before a command runs — here the expansion is a value
/// you can inspect, and each match reaches the child as one literal argument.
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
  let raw = split_path(pattern)
  let absolute = raw is [first, ..] && first.is_empty()
  // A trailing `/` asks for directories only; it is not a segment.
  let directories_only = raw.length() > 1 &&
    raw[raw.length() - 1].is_empty() &&
    !(absolute && raw.length() == 2)
  let segments = []
  for index, segment in raw {
    // Empty segments are separator noise; the leading one only marked the
    // pattern absolute, and the trailing one only asked for directories.
    if !segment.is_empty() || (index == 0 && !absolute) {
      if !segment.is_empty() {
        segments.push(segment)
      }
    }
  }
  let (base, prefix) = if absolute { ("/", "/") } else { (cwd, "") }
  let found = []
  let seen = Map([])
  expand(base, prefix, segments[:], directories_only, found, seen)
  found.sort_by(compare_code_units)
  found
}

///|
/// Compare two strings by code unit, then by length.
///
/// `Array::sort` on strings orders by length first, which would list
/// "plain.txt" before "od d*name.txt". A shell does not.
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
/// filesystem call uses `base` and every recorded result `prefix`. `seen`
/// records the results already produced, because two `**` in one pattern can
/// otherwise reach the same path by more than one route.
async fn expand(
  base : String,
  prefix : String,
  segments : ArrayView[String],
  directories_only : Bool,
  found : Array[String],
  seen : Map[String, Unit],
) -> Unit {
  match segments {
    [] =>
      if !prefix.is_empty() &&
        !seen.contains(prefix) &&
        @fs.exists(base) &&
        (!directories_only || is_directory(base)) {
        seen[prefix] = ()
        found.push(if directories_only { prefix + "/" } else { prefix })
      }
    ["**", .. rest] => {
      // `**` matches no segments at all, then every visible subdirectory in
      // turn. Symlinked directories are not descended, so a link to an
      // ancestor cannot loop.
      expand(base, prefix, rest, directories_only, found, seen)
      for entry in read_directory(base) {
        if !is_hidden(entry) {
          let child_base = join(base, entry)
          let child_prefix = join(prefix, entry)
          if is_real_directory(child_base) {
            expand(
              child_base, child_prefix, segments, directories_only, found, seen,
            )
          } else if rest is [] {
            // `**` may also end on something that is not a directory, so a
            // trailing globstar yields ordinary files too.
            expand(
              child_base, child_prefix, rest, directories_only, found, seen,
            )
          }
        }
      }
    }
    [segment, .. rest] =>
      if is_literal_segment(segment) {
        // Nothing to search: descend directly and let the final check decide.
        let literal = unescape(segment)
        let child = join(base, literal)
        if rest is [] {
          expand(
            child,
            join(prefix, literal),
            rest,
            directories_only,
            found,
            seen,
          )
        } else if is_directory(child) {
          expand(
            child,
            join(prefix, literal),
            rest,
            directories_only,
            found,
            seen,
          )
        }
      } else {
        for entry in read_directory(base) {
          if match_segment(segment, entry) {
            let child = join(base, entry)
            if rest is [] {
              expand(
                child,
                join(prefix, entry),
                rest,
                directories_only,
                found,
                seen,
              )
            } else if is_directory(child) {
              expand(
                child,
                join(prefix, entry),
                rest,
                directories_only,
                found,
                seen,
              )
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
/// Whether a segment has no metacharacters, so it needs no directory listing.
fn is_literal_segment(segment : String) -> Bool {
  for item in parse_segment(segment) {
    if !(item is Literal(_)) {
      return false
    }
  }
  true
}

///|
/// Resolve a literal segment's escapes to the name it actually denotes.
fn unescape(segment : String) -> String {
  let text = StringBuilder()
  for item in parse_segment(segment) {
    if item is Literal(char) {
      text.write_char(char)
    }
  }
  text.to_string()
}

///|
/// List a directory, treating one that cannot be read as empty.
///
/// `.` and `..` are never produced: a pattern should not be able to walk back
/// out of the tree it is expanding.
async fn read_directory(path : String) -> Array[String] {
  @fs.readdir(path, include_hidden=true) catch {
    _ => []
  }
}

///|
/// Whether the path is a directory and not a symbolic link to one.
async fn is_real_directory(path : String) -> Bool {
  (@fs.kind(path, follow_symlink=false) catch { _ => return false })
  is Directory
}

///|
/// Whether the path is a directory, resolving a symbolic link to one.
///
/// This is what an explicitly named or wildcard-matched component uses: naming
/// `/var/log/*` has to work on a system where `/var` is a link, exactly as it
/// does in a shell. Only `**` declines to follow links, to stop a link
/// pointing at an ancestor from making the walk run forever.
async fn is_directory(path : String) -> Bool {
  (@fs.kind(path) catch { _ => return false }) is Directory
}
