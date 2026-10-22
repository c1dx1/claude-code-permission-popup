import Foundation

// Logic shared by the app and its tests: no AppKit and no process-wide state.

func json(_ value: Any, pretty: Bool = true) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    if pretty { options.insert(.prettyPrinted) }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Paths

struct PathShortener {
    let cwd: String
    let home: String

    // Display only: Claude Code still runs exactly what it sent.
    func shorten(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"(?:/private)?/tmp/claude-\d+/[^/\s'"]+/[0-9a-f-]{36}"#, with: "…", options: .regularExpression
        )
        for (path, replacement) in [(cwd, "."), (home, "~")] where path.count > 1 {
            let pattern = NSRegularExpression.escapedPattern(for: path) + #"(?=[/\s'":;)|&]|$)"#
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    func display(_ path: String) -> String {
        let short = shorten(path)
        return short.hasPrefix("./") ? String(short.dropFirst(2)) : short
    }
}

// MARK: - Shell

enum ShellToken: Equatable {
    case plain, command, keyword, op, variable, string, flag, redirect, comment
}

struct ShellSegment: Equatable {
    let text: String
    let token: ShellToken
}

let shellKeywords: Set<String> = ["if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "!", "{", "}"]
let commandPrefixes: Set<String> = ["sudo", "time", "nohup", "exec", "command"]

// Splits a shell command into highlighted segments and puts each link of a long one-line chain on its own line.
struct ShellFormatter {
    private let chars: [Character]
    private let indent: String
    private let wrap: Bool
    private var i = 0
    private var expectCommand = true
    private var awaitingDelimiter = false
    private var heredocDelimiter: String?
    private var segments: [ShellSegment] = []

    init(_ command: String, indent: String) {
        chars = Array(command)
        self.indent = indent
        wrap = command.count > 72 && !command.contains("\n")
    }

    mutating func format() -> [ShellSegment] {
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\n":
                emit("\n", .plain)
                i += 1
                expectCommand = true
                if let delimiter = heredocDelimiter {
                    readHeredoc(until: delimiter)
                    heredocDelimiter = nil
                }
            case " ", "\t":
                emit(String(c), .plain)
                i += 1
            case "#" where expectCommand || (i > 0 && chars[i - 1].isWhitespace):
                var comment = ""
                while i < chars.count, chars[i] != "\n" {
                    comment.append(chars[i])
                    i += 1
                }
                emit(comment, .comment)
            default:
                if let op = ["&&", "||", ";;", "|", ";"].first(where: matches) {
                    emitOperator(op)
                } else {
                    emitWord(readWord())
                }
            }
        }
        return segments
    }

    private mutating func emit(_ text: String, _ token: ShellToken) {
        segments.append(ShellSegment(text: text, token: token))
    }

    private func matches(_ token: String) -> Bool {
        let token = Array(token)
        return i + token.count <= chars.count && Array(chars[i ..< i + token.count]) == token
    }

    private mutating func emitOperator(_ op: String) {
        i += op.count
        emit(op, .op)
        expectCommand = true
        guard wrap else { return }
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i < chars.count { emit("\n" + indent, .plain) }
    }

    private mutating func readWord() -> String {
        var word = ""
        var quote: Character?
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if let open = quote {
                word.append(c)
                i += 1
                if c == "\\", open == "\"", i < chars.count {
                    word.append(chars[i])
                    i += 1
                } else if c == open {
                    quote = nil
                }
                continue
            }
            if depth == 0, c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || matches("&&") { break }
            switch c {
            case "'", "\"": quote = c
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case "\\" where i + 1 < chars.count:
                word.append(c)
                i += 1
            default: break
            }
            word.append(chars[i])
            i += 1
        }
        return word
    }

    private mutating func emitWord(_ word: String) {
        if awaitingDelimiter {
            awaitingDelimiter = false
            heredocDelimiter = Self.delimiter(word)
            return emit(word, .redirect)
        }
        if word.hasPrefix("<<"), !word.hasPrefix("<<<") {
            let rest = String(word.dropFirst(2))
            if rest.isEmpty || rest == "-" { awaitingDelimiter = true } else { heredocDelimiter = Self.delimiter(rest) }
            return emit(word, .redirect)
        }
        guard expectCommand else { return emit(word, Self.token(of: word)) }

        if let equals = word.firstIndex(of: "="), let first = word.first, !first.isNumber, first != "=",
           word[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            emit(String(word[..<equals]), .variable)
            return emit(String(word[equals...]), .plain)
        }
        if shellKeywords.contains(word) { return emit(word, .keyword) }
        emit(word, .command)
        expectCommand = commandPrefixes.contains(word)
    }

    private mutating func readHeredoc(until delimiter: String) {
        while i < chars.count {
            var line = ""
            while i < chars.count, chars[i] != "\n" {
                line.append(chars[i])
                i += 1
            }
            let isEnd = line.trimmingCharacters(in: .whitespaces) == delimiter
            emit(line, isEnd ? .redirect : .string)
            if i < chars.count {
                emit("\n", .plain)
                i += 1
            }
            if isEnd { return }
        }
    }

    private static func delimiter(_ word: String) -> String {
        String(word.drop(while: { $0 == "-" })).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func token(of word: String) -> ShellToken {
        guard let first = word.first else { return .plain }
        switch first {
        case "'", "\"": return .string
        case "-": return .flag
        case "$": return .variable
        case ">", "<": return .redirect
        default: return first.isNumber && word.dropFirst().first == ">" ? .redirect : .plain
        }
    }
}

func formatShell(_ command: String, indent: String) -> [ShellSegment] {
    var formatter = ShellFormatter(command, indent: indent)
    return formatter.format()
}

// MARK: - Diff

func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

enum DiffLine: Equatable {
    case same(String), removed(String), inserted(String)
}

func diffLines(old: String, new: String) -> [DiffLine] {
    let a = splitLines(old), b = splitLines(new)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in b.difference(from: a) {
        switch change {
        case let .remove(offset, _, _): removed.insert(offset)
        case let .insert(offset, _, _): inserted.insert(offset)
        }
    }
    var out: [DiffLine] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, removed.contains(i) {
            out.append(.removed(a[i]))
            i += 1
        } else if j < b.count, inserted.contains(j) {
            out.append(.inserted(b[j]))
            j += 1
        } else if i < a.count, j < b.count {
            out.append(.same(a[i]))
            i += 1
            j += 1
        } else {
            break
        }
    }
    return out
}

// MARK: - Danger

// Requests worth a second look: the card turns red and Return, the hotkey and temporary grants stop allowing them.
private let dangerousCommands: [(label: String, pattern: String)] = [
    ("rm -r", #"\brm\s+(-\S+\s+)*-[a-zA-Z]*[rR]"#),
    ("sudo", #"(^|[;&|(]\s*|\s)sudo\s"#),
    ("git push --force", #"\bgit\s+push\b[^;&|]*\s(--force(-with-lease)?|-f)\b"#),
    ("git reset --hard", #"\bgit\s+reset\b[^;&|]*--hard"#),
    ("git clean -f", #"\bgit\s+clean\b[^;&|]*\s-[a-zA-Z]*f"#),
    ("curl | sh", #"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#),
    ("chmod 777", #"\bchmod\s+(-R\s+)?777\b"#),
    ("dd / mkfs", #"\b(mkfs(\.\w+)?|dd\s+if=)"#),
    ("DROP / TRUNCATE", #"(?i)\b(drop\s+(table|database|schema)|truncate\s+table)\b"#),
    ("kubectl delete", #"\bkubectl\s+delete\b"#),
    ("terraform", #"\bterraform\s+(destroy|apply)\b"#),
    ("prod", #"(?i)(^|[^a-z0-9])prod(uction)?([^a-z0-9]|$)"#),
]

private let dangerousPaths: [(label: String, pattern: String)] = [
    (".env", #"(^|/)\.env(\.[^/]*)?$"#),
    ("~/.ssh", #"/\.ssh/"#),
    (".git", #"/\.git/"#),
    ("prod", #"(?i)(^|[^a-z0-9])prod(uction)?([^a-z0-9]|$)"#),
]

func dangerLabel(toolName: String, input: [String: Any]) -> String? {
    let (subject, patterns): (String?, [(label: String, pattern: String)]) = switch toolName {
    case "Bash": (input["command"] as? String, dangerousCommands)
    case "Edit", "Write", "MultiEdit": (input["file_path"] as? String, dangerousPaths)
    case "NotebookEdit": (input["notebook_path"] as? String, dangerousPaths)
    default: (nil, [])
    }
    guard let subject else { return nil }
    return patterns.first { subject.range(of: $0.pattern, options: .regularExpression) != nil }?.label
}

// MARK: - Permission rules

// The subset of Claude Code's rule syntax needed to honour temporary grants: "Tool" or "Tool(content)".
struct PermissionRule: Equatable {
    let tool: String
    let content: String?

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        let open = text.firstIndex(of: "(")
        let tool = String(text[..<(open ?? text.endIndex)])
        guard tool.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        self.tool = tool
        guard let open else {
            content = nil
            return
        }
        guard text.hasSuffix(")") else { return nil }
        content = String(text[text.index(after: open) ..< text.index(before: text.endIndex)])
    }

    func matches(toolName: String, input: [String: Any], cwd: String, home: String) -> Bool {
        guard toolName == tool || toolName.hasPrefix(tool + "__") && tool.hasPrefix("mcp__") else { return false }
        guard let content else { return true }
        switch toolName {
        case "Bash":
            return Self.commandMatches(input["command"] as? String ?? "", content)
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            return fnmatch(Self.absolutePattern(content, cwd: cwd, home: home), path, 0) == 0
        case "WebFetch":
            guard content.hasPrefix("domain:"), let host = URL(string: input["url"] as? String ?? "")?.host else { return false }
            let domain = String(content.dropFirst("domain:".count))
            return host == domain || host.hasSuffix("." + domain)
        default:
            return false
        }
    }

    private static func commandMatches(_ command: String, _ content: String) -> Bool {
        var prefix = content
        if content.hasSuffix(":*") || content.hasSuffix(" *") {
            prefix = String(content.dropLast(2))
        } else {
            return command == content
        }
        // A prefix grant must not stretch to whatever gets chained after the command.
        let chained = ["&&", "||", ";", "|", "`", "$(", "\n"].contains { command.contains($0) }
        return !chained && (command == prefix || command.hasPrefix(prefix + " "))
    }

    private static func absolutePattern(_ content: String, cwd: String, home: String) -> String {
        if content.hasPrefix("//") { return String(content.dropFirst()) }
        if content.hasPrefix("~/") { return home + content.dropFirst() }
        if content.hasPrefix("/") { return cwd + content }
        return cwd + "/" + content
    }
}

// MARK: - Temporary grants

struct Grant: Codable, Equatable {
    let cwd: String
    let rule: String?
    let toolName: String
    let input: String?
    let expires: Date
}

// "Allow for N minutes": by Claude Code's suggested rule when there is one, otherwise for this exact call.
struct GrantStore {
    let url: URL

    static var standard: GrantStore {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/permission-popup")
        return GrantStore(url: dir.appendingPathComponent("grants.json"))
    }

    func active(now: Date = Date()) -> [Grant] {
        guard let data = try? Data(contentsOf: url), let grants = try? JSONDecoder().decode([Grant].self, from: data) else { return [] }
        return grants.filter { $0.expires > now }
    }

    func add(_ grant: Grant, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(active(now: now) + [grant]).write(to: url, options: .atomic)
    }

    func allows(toolName: String, input: [String: Any], cwd: String, home: String, now: Date = Date()) -> Bool {
        let exact = json(input, pretty: false)
        return active(now: now).contains { grant in
            guard grant.cwd == cwd else { return false }
            if let rule = grant.rule.flatMap(PermissionRule.init) {
                return rule.matches(toolName: toolName, input: input, cwd: cwd, home: home)
            }
            return grant.toolName == toolName && grant.input == exact
        }
    }
}

// MARK: - Generic tool input

func summarize(_ input: [String: Any]) -> [(key: String, value: String)] {
    input.keys.sorted().map { key in
        let value = input[key]
        return (key, value as? String ?? json(value ?? NSNull(), pretty: false))
    }
}
