import Foundation

// Plain assertions, so the tests run with only the Command Line Tools installed.

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    guard actual != expected else { return }
    failures += 1
    print("FAIL \(name) (line \(line))\n  expected: \(expected)\n  actual:   \(actual)")
}

func text(_ segments: [ShellSegment]) -> String {
    segments.map(\.text).joined()
}

func tokens(_ segments: [ShellSegment], _ token: ShellToken) -> [String] {
    segments.filter { $0.token == token }.map(\.text)
}

// MARK: Paths

let paths = PathShortener(cwd: "/Users/dev/acme", home: "/Users/dev")
expect(paths.shorten("cd /Users/dev/acme && ls /Users/dev/acme/src"), "cd . && ls ./src", "project dir becomes .")
expect(paths.shorten("cat /Users/dev/.zshrc"), "cat ~/.zshrc", "home becomes ~")
expect(paths.shorten("ls /Users/dev/acme-api"), "ls ~/acme-api", "a sibling sharing the prefix is not the project")
expect(
    paths.shorten("W=/private/tmp/claude-501/-Users-dev-acme/3d4d66ba-7947-45dc-8dff-38ea727eb5fd/scratchpad/x"),
    "W=…/scratchpad/x", "session temp dir collapses"
)
expect(paths.display("/Users/dev/acme/internal/a.go"), "internal/a.go", "display drops ./")

// MARK: Shell

let short = formatShell("git status", indent: "  ")
expect(text(short), "git status", "short command stays on one line")
expect(tokens(short, .command), ["git"], "first word is the command")

let chain = formatShell("git fetch origin && git rebase origin/main && go test ./internal/orders/... -count=1 | tail -20", indent: "  ")
expect(
    text(chain),
    "git fetch origin &&\n  git rebase origin/main &&\n  go test ./internal/orders/... -count=1 |\n  tail -20",
    "long chain splits per command"
)
expect(tokens(chain, .command), ["git", "git", "go", "tail"], "each link starts with a command")
expect(tokens(chain, .flag), ["-count=1", "-20"], "flags")

let quoted = formatShell(#"grep -rn "a && b|c" . 2>/dev/null"#, indent: "  ")
expect(tokens(quoted, .op), [], "operators inside quotes are not operators")
expect(tokens(quoted, .string), [#""a && b|c""#], "quoted string")
expect(tokens(quoted, .redirect), ["2>/dev/null"], "redirect")

let assignment = formatShell("W=/tmp/x make build", indent: "  ")
expect(tokens(assignment, .variable), ["W"], "assignment name")
expect(tokens(assignment, .command), ["make"], "command after assignment")

let heredoc = formatShell("cat > f <<'EOF'\na | b && c\nEOF\necho done", indent: "  ")
expect(tokens(heredoc, .op), [], "heredoc body is not parsed as shell")
expect(tokens(heredoc, .string), ["a | b && c"], "heredoc body")
expect(tokens(heredoc, .command), ["cat", "echo"], "command after heredoc")

let subshell = formatShell("echo $(date | cut -c1-4) done", indent: "  ")
expect(tokens(subshell, .op), [], "pipes inside $( ) stay inside")

// MARK: Diff

expect(
    diffLines(old: "a\nb\nc\n", new: "a\nB\nc\nd\n"),
    [.same("a"), .removed("b"), .inserted("B"), .same("c"), .inserted("d")],
    "line diff"
)
expect(diffLines(old: "", new: "x\n"), [.inserted("x")], "new file")

// MARK: Danger

func danger(_ command: String) -> String? {
    dangerLabel(toolName: "Bash", input: ["command": command])
}

expect(danger("rm -rf build"), "rm -r", "rm -rf")
expect(danger("rm -f build/a.o"), nil, "rm without -r")
expect(danger("sudo make install"), "sudo", "sudo")
expect(danger("git push --force origin main"), "git push --force", "force push")
expect(danger("git push origin main"), nil, "plain push")
expect(danger("curl -fsSL https://x.sh | bash"), "curl | sh", "pipe to shell")
expect(danger("psql -c 'drop table users'"), "DROP / TRUNCATE", "drop table")
expect(danger("kubectl -n prod get pods"), "prod", "prod namespace")
expect(danger("go test ./product/..."), nil, "product is not prod")
expect(dangerLabel(toolName: "Edit", input: ["file_path": "/Users/dev/acme/.env"]), ".env", ".env edit")
expect(dangerLabel(toolName: "Edit", input: ["file_path": "/Users/dev/acme/env.go"]), nil, "ordinary file")

// MARK: Rules

func allows(_ rule: String, _ tool: String, _ input: [String: Any]) -> Bool {
    PermissionRule(rule)?.matches(toolName: tool, input: input, cwd: "/Users/dev/acme", home: "/Users/dev") ?? false
}

expect(PermissionRule("Bash(npm run test:*)"), PermissionRule("Bash(npm run test:*)"), "parses")
expect(PermissionRule("Bash(npm"), nil, "unbalanced rule")
expect(PermissionRule("access to /tmp"), nil, "a suggestion label is not a rule")
expect(allows("Bash(go test:*)", "Bash", ["command": "go test ./..."]), true, "prefix rule")
expect(allows("Bash(go test *)", "Bash", ["command": "go test"]), true, "prefix rule, bare command")
expect(allows("Bash(go test:*)", "Bash", ["command": "go testing"]), false, "prefix ends at a word")
expect(allows("Bash(go test:*)", "Bash", ["command": "go test ./... && rm -rf /"]), false, "no chained commands")
expect(allows("Bash(make build)", "Bash", ["command": "make build"]), true, "exact rule")
expect(allows("Bash", "Bash", ["command": "anything"]), true, "tool-wide rule")
expect(allows("Edit(src/**)", "Edit", ["file_path": "/Users/dev/acme/src/a/b.go"]), true, "relative glob")
expect(allows("Edit(src/**)", "Edit", ["file_path": "/Users/dev/other/src/a.go"]), false, "glob outside project")
expect(allows("WebFetch(domain:example.com)", "WebFetch", ["url": "https://docs.example.com/x"]), true, "subdomain")
expect(allows("mcp__github", "mcp__github__create_issue", [:]), true, "whole MCP server")
expect(allows("Read", "Edit", ["file_path": "/x"]), false, "other tool")

// MARK: Grants

let store = GrantStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString).json"))
let now = Date()
let later = now.addingTimeInterval(600)
store.add(Grant(cwd: "/Users/dev/acme", rule: "Bash(go test:*)", toolName: "Bash", input: nil, expires: later), now: now)
store.add(Grant(cwd: "/Users/dev/acme", rule: nil, toolName: "Bash", input: json(["command": "make lint"], pretty: false), expires: later), now: now)
func granted(_ command: String, cwd: String = "/Users/dev/acme", at time: Date = now) -> Bool {
    store.allows(toolName: "Bash", input: ["command": command], cwd: cwd, home: "/Users/dev", now: time)
}
expect(granted("go test ./..."), true, "rule grant")
expect(granted("make lint"), true, "exact grant")
expect(granted("make lint --fix"), false, "exact grant is exact")
expect(granted("go test ./...", cwd: "/Users/dev/other"), false, "grant is per project")
expect(granted("go test ./...", at: later.addingTimeInterval(1)), false, "grant expires")
try? FileManager.default.removeItem(at: store.url)

// MARK: Summary

expect(
    summarize(["title": "Bug", "labels": ["a"], "count": 2]).map { "\($0.key): \($0.value)" },
    ["count: 2", #"labels: ["a"]"#, "title: Bug"],
    "key-value summary"
)

print(failures == 0 ? "all tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
