///|
/// A repository dashboard from three `gh` queries: open PRs, CI health, and
/// issue labels.
///
/// The shell version runs them one after another and leans on jq:
///
///   gh pr list --json ... | jq -r '...'
///   gh run list --json ... | jq -r '...' | sort | uniq -c
///   gh issue list --json ... | jq -r '.[].labels[].name' | sort | uniq -c
///
/// Here the three queries run concurrently in one structured task group
/// (replacing `&` and `wait`), the answers are destructured with native JSON
/// pattern matching, and `lexmatch` trims ISO timestamps down to a day.
///
///   moon run --target native examples/gh_dashboard [owner/repo]

///|
async fn fetch(args : Array[String]) -> Json {
  let output = @myshell.Cmd("gh", args).output()
  if !output.success() {
    println("gh \{args.join(" ")} failed: \{output.stderr.trim()}")
    return []
  }
  @json.parse(output.stdout) catch {
    _ => []
  }
}

///|
fn day_of(timestamp : String) -> String {
  lexmatch timestamp {
    (re"^[0-9]{4}-[0-9]{2}-[0-9]{2}" as day, after=_rest) => day.to_owned()
    _ => timestamp
  }
}

///|
async fn main {
  let repo : Array[String] = if @env.args() is [_, name, ..] {
    ["-R", name]
  } else {
    []
  }
  let mut prs : Json = []
  let mut runs : Json = []
  let mut issues : Json = []
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      prs = fetch(
        [
          ..repo, "pr", "list", "--json", "number,title,isDraft,reviewDecision,updatedAt",
          "--limit", "50",
        ],
      )
    })
    group.spawn_bg(() => {
      runs = fetch(
        [
          ..repo, "run", "list", "--json", "workflowName,conclusion", "--limit",
          "30",
        ],
      )
    })
    group.spawn_bg(() => {
      issues = fetch(
        [..repo, "issue", "list", "--json", "labels", "--limit", "100"],
      )
    })
  })
  guard (prs, runs, issues)
    is (Array(pr_items), Array(run_items), Array(issue_items)) else {
    println("unexpected gh output")
    return
  }
  println("open PRs: \{pr_items.length()}")
  for item in pr_items {
    guard item
      is {
        "number": Number(number, ..),
        "title": String(title),
        "reviewDecision": String(decision),
        "updatedAt": String(updated),
        ..
      } else {
      continue
    }
    let state = if item is { "isDraft": true, .. } {
      "draft"
    } else if decision is "" {
      "unreviewed"
    } else {
      decision
    }
    println("  #\{number.to_int()} [\{state}] \{title} (\{day_of(updated)})")
  }
  println("\nCI, last \{run_items.length()} runs:")
  let ci : Map[String, Map[String, Int]] = Map([])
  for item in run_items {
    guard item
      is { "workflowName": String(name), "conclusion": String(conclusion), .. } else {
      continue
    }
    let per = ci.get_or_init(name, () => Map([]))
    let key = if conclusion is "" { "in progress" } else { conclusion }
    per[key] = per.get(key).unwrap_or(0) + 1
  }
  for name, per in ci {
    let parts = per.to_array().map(pair => "\{pair.1} \{pair.0}")
    println("  \{name}: \{parts.join(", ")}")
  }
  println("\nopen issues: \{issue_items.length()}")
  let labels : Map[String, Int] = Map([])
  for item in issue_items {
    guard item is { "labels": Array(entries), .. } else { continue }
    if entries is [] {
      labels["(unlabeled)"] = labels.get("(unlabeled)").unwrap_or(0) + 1
    }
    for entry in entries {
      if entry is { "name": String(name), .. } {
        labels[name] = labels.get(name).unwrap_or(0) + 1
      }
    }
  }
  let rows = labels.to_array()
  rows.sort_by_key(row => -row.1)
  for row in rows {
    println("  \{row.1}\t\{row.0}")
  }
}
