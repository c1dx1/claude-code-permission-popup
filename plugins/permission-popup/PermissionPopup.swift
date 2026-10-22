import AppKit

// Claude Code PermissionRequest hook: a notification-style card with Allow/Deny, the full request in a window on demand.
// System notifications hide action buttons behind an "Options" menu, hence a card of our own.
// Printing nothing (closed, timeout) leaves the decision to Claude Code's own prompt.

let environment = ProcessInfo.processInfo.environment
// An unanswered card hands the question back to Claude Code's own prompt instead of holding the session.
let cardTimeout = TimeInterval(environment["PERMISSION_POPUP_TIMEOUT"] ?? "") ?? 15
// Stays under the 600 s hook timeout in settings.json.
let windowTimeout: TimeInterval = 540
// Their answers are richer than allow/deny, so only Claude Code's own UI can collect them.
let passthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

// The chat open in the frontmost Claude app already shows Claude Code's own prompt; a card would only repeat it.
func isOpenInFrontClaudeApp() -> Bool {
    guard let session = environment["CLAUDE_CODE_HOST_SESSION_ID"],
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop"
    else { return false }
    // Undocumented app state: if its shape changes, the card just keeps showing.
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    guard let data = try? Data(contentsOf: url),
          let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let panes = ((config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])?["desktop-frame.paneStore.v1"],
          let panesData = try? JSONSerialization.data(withJSONObject: panes)
    else { return false }
    return String(decoding: panesData, as: UTF8.self).contains("\"\(session)\"")
}

let input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
let toolName = input["tool_name"] as? String ?? ""
if toolName.isEmpty || passthroughTools.contains(toolName) || isOpenInFrontClaudeApp() { exit(0) }

let toolInput = input["tool_input"] as? [String: Any] ?? [:]
let suggestions = input["permission_suggestions"] as? [[String: Any]] ?? []
let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let projectName = (cwd as NSString).lastPathComponent

// Follows the system language: Russian when it comes first, English otherwise.
let usesRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true

func tr(_ english: String, _ russian: String) -> String {
    usesRussian ? russian : english
}

func respond(_ decision: [String: Any]) -> Never {
    let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

func allow() -> Never {
    respond(["behavior": "allow"])
}

func allowAlways() -> Never {
    respond(["behavior": "allow", "updatedPermissions": suggestions])
}

// Stops Claude like the built-in "No" does.
func deny() -> Never {
    respond(["behavior": "deny", "message": "The user denied this tool call.", "interrupt": true])
}

func leaveToClaude() -> Never {
    exit(0)
}

// MARK: - Style

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

func dynamicColor(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { appearance in
        NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: alpha)
    }
}

// Claude's warm neutrals around its clay-orange accent.
enum Palette {
    static let background = dynamicColor(light: 0xFAF9F5, dark: 0x262624)
    static let surface = dynamicColor(light: 0xF0EEE6, dark: 0x1F1E1D)
    static let border = dynamicColor(light: 0xE3E0D5, dark: 0x3A3935)
    static let text = dynamicColor(light: 0x141413, dark: 0xF5F4EE)
    static let secondary = dynamicColor(light: 0x6F6D66, dark: 0xA6A39A)
    static let tertiary = dynamicColor(light: 0xA19E94, dark: 0x75726B)
    static let accent = dynamicColor(light: 0xC96442, dark: 0xD97757)
    static let string = dynamicColor(light: 0x5A7A3A, dark: 0xA9C88F)
    static let variable = dynamicColor(light: 0x7A5BA6, dark: 0xBBA3DE)
    static let removed = dynamicColor(light: 0xA8402E, dark: 0xF0A090)
    static let removedBackground = dynamicColor(light: 0xC9553D, dark: 0xE07A62, alpha: 0.13)
    static let inserted = dynamicColor(light: 0x3F6E2A, dark: 0xA8D18F)
    static let insertedBackground = dynamicColor(light: 0x5C9A3E, dark: 0x7FBF62, alpha: 0.14)
}

let codeSize: CGFloat = 12.5
let previewSize: CGFloat = 11.5

func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

func appIcon() -> NSImage {
    // Read straight from the bundle: LaunchServices keeps serving a stale generic icon for a while.
    Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
}

// MARK: - Rendering

let maxRenderedLines = 3000

extension NSMutableAttributedString {
    func add(_ text: String, font: NSFont = mono(codeSize), color: NSColor = Palette.text, background: NSColor? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        attributes[.backgroundColor] = background
        append(NSAttributedString(string: text, attributes: attributes))
    }
}

func plain(_ text: String, font: NSFont = mono(codeSize), color: NSColor = Palette.text) -> NSAttributedString {
    let out = NSMutableAttributedString()
    out.add(text, font: font, color: color)
    return out
}

// Display only: Claude Code still runs exactly what it sent, and the code's tooltip shows it as is.
func shortenPaths(_ text: String) -> String {
    var out = text.replacingOccurrences(
        of: #"(?:/private)?/tmp/claude-\d+/[^/\s'"]+/[0-9a-f-]{36}"#, with: "…", options: .regularExpression
    )
    for (path, replacement) in [(cwd, "."), (NSHomeDirectory(), "~")] where path.count > 1 {
        let pattern = NSRegularExpression.escapedPattern(for: path) + #"(?=[/\s'":;)|&]|$)"#
        out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return out
}

func displayPath(_ path: String) -> String {
    let short = shortenPaths(path)
    return short.hasPrefix("./") ? String(short.dropFirst(2)) : short
}

let shellKeywords: Set<String> = ["if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "!", "{", "}"]
let commandPrefixes: Set<String> = ["sudo", "time", "nohup", "exec", "command"]

// Colors a shell command and puts each link of a long one-line chain on its own line.
struct ShellFormatter {
    private let chars: [Character]
    private let indent: String
    private let size: CGFloat
    private let wrap: Bool
    private var i = 0
    private var expectCommand = true
    private var awaitingDelimiter = false
    private var heredocDelimiter: String?
    private var text = NSMutableAttributedString()

    init(_ command: String, indent: String, size: CGFloat) {
        chars = Array(command)
        self.indent = indent
        self.size = size
        wrap = command.count > 72 && !command.contains("\n")
    }

    mutating func format() -> NSAttributedString {
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\n":
                emit("\n", Palette.text)
                i += 1
                expectCommand = true
                if let delimiter = heredocDelimiter {
                    readHeredoc(until: delimiter)
                    heredocDelimiter = nil
                }
            case " ", "\t":
                emit(String(c), Palette.text)
                i += 1
            case "#" where expectCommand || (i > 0 && chars[i - 1].isWhitespace):
                var comment = ""
                while i < chars.count, chars[i] != "\n" {
                    comment.append(chars[i])
                    i += 1
                }
                emit(comment, Palette.tertiary)
            default:
                if let op = ["&&", "||", ";;", "|", ";"].first(where: matches) {
                    emitOperator(op)
                } else {
                    emitWord(readWord())
                }
            }
        }
        return text
    }

    private mutating func emit(_ s: String, _ color: NSColor, bold: Bool = false) {
        text.add(s, font: mono(size, bold: bold), color: color)
    }

    private func matches(_ token: String) -> Bool {
        let token = Array(token)
        return i + token.count <= chars.count && Array(chars[i ..< i + token.count]) == token
    }

    private mutating func emitOperator(_ op: String) {
        i += op.count
        emit(op, Palette.accent, bold: true)
        expectCommand = true
        guard wrap else { return }
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i < chars.count { emit("\n" + indent, Palette.text) }
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
            return emit(word, Palette.tertiary)
        }
        if word.hasPrefix("<<"), !word.hasPrefix("<<<") {
            let rest = String(word.dropFirst(2))
            if rest.isEmpty || rest == "-" { awaitingDelimiter = true } else { heredocDelimiter = Self.delimiter(rest) }
            return emit(word, Palette.tertiary)
        }
        guard expectCommand else { return emit(word, Self.color(of: word)) }

        if let equals = word.firstIndex(of: "="), let first = word.first, !first.isNumber, first != "=",
           word[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            emit(String(word[..<equals]), Palette.variable)
            return emit(String(word[equals...]), Palette.text)
        }
        if shellKeywords.contains(word) { return emit(word, Palette.accent) }
        emit(word, Palette.text, bold: true)
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
            emit(line, isEnd ? Palette.tertiary : Palette.string)
            if i < chars.count {
                emit("\n", Palette.text)
                i += 1
            }
            if isEnd { return }
        }
    }

    private static func delimiter(_ word: String) -> String {
        String(word.drop(while: { $0 == "-" })).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func color(of word: String) -> NSColor {
        guard let first = word.first else { return Palette.text }
        switch first {
        case "'", "\"": return Palette.string
        case "-": return Palette.secondary
        case "$": return Palette.variable
        case ">", "<": return Palette.tertiary
        default: return first.isNumber && word.dropFirst().first == ">" ? Palette.tertiary : Palette.text
        }
    }
}

func formatShell(_ command: String, indent: String, size: CGFloat) -> NSAttributedString {
    var formatter = ShellFormatter(command, indent: indent, size: size)
    return formatter.format()
}

// Soft-wrapped tails of long lines continue under the code instead of at column zero.
func withHangingIndent(_ text: NSAttributedString, columns: Int) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.headIndent = ("0" as NSString).size(withAttributes: [.font: mono(codeSize)]).width * CGFloat(columns)
    style.lineSpacing = 2
    let out = NSMutableAttributedString(attributedString: text)
    out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
    return out
}

func highlightJSON(_ json: String) -> NSAttributedString {
    let out = NSMutableAttributedString(string: json, attributes: [.font: mono(codeSize), .foregroundColor: Palette.text])
    let ns = json as NSString
    guard let strings = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) else { return out }
    for match in strings.matches(in: json, range: NSRange(location: 0, length: ns.length)) {
        var next = match.range.upperBound
        while next < ns.length, ns.character(at: next) == UInt16(UInt8(ascii: " ")) { next += 1 }
        let isKey = next < ns.length && ns.character(at: next) == UInt16(UInt8(ascii: ":"))
        out.addAttribute(.foregroundColor, value: isKey ? Palette.variable : Palette.string, range: match.range)
    }
    return out
}

func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

enum DiffLine {
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

func renderDiff(_ lines: [DiffLine], context: Int = 3) -> NSAttributedString {
    var visible = Set<Int>()
    for (index, line) in lines.enumerated() {
        if case .same = line { continue }
        visible.formUnion(max(0, index - context)...min(lines.count - 1, index + context))
    }

    let out = NSMutableAttributedString()
    var skipped = 0, rendered = 0
    func flushSkipped() {
        guard skipped > 0 else { return }
        out.add(tr("  ⋯ unchanged: \(skipped)\n", "  ⋯ без изменений: \(skipped)\n"), color: Palette.tertiary)
        skipped = 0
    }
    for (index, line) in lines.enumerated() {
        guard visible.contains(index) else {
            skipped += 1
            continue
        }
        guard rendered < maxRenderedLines else {
            out.add(tr("… truncated\n", "… дальше обрезано\n"), color: Palette.tertiary)
            return out
        }
        flushSkipped()
        switch line {
        case let .same(text):
            out.add("  \(text)\n", color: Palette.secondary)
        case let .removed(text):
            out.add("- \(text)\n", color: Palette.removed, background: Palette.removedBackground)
        case let .inserted(text):
            out.add("+ \(text)\n", color: Palette.inserted, background: Palette.insertedBackground)
        }
        rendered += 1
    }
    flushSkipped()
    return out
}

func previewDiff(_ lines: [DiffLine]) -> NSAttributedString {
    let changed = lines.compactMap { line -> (String, NSColor)? in
        switch line {
        case .same: return nil
        case let .removed(text): return ("− " + text, Palette.removed)
        case let .inserted(text): return ("+ " + text, Palette.inserted)
        }
    }
    let out = NSMutableAttributedString()
    for (index, (text, color)) in changed.prefix(6).enumerated() {
        out.add((index > 0 ? "\n" : "") + text, font: mono(previewSize), color: color)
    }
    return out
}

func string(_ key: String) -> String {
    toolInput[key] as? String ?? ""
}

func json(_ value: Any, pretty: Bool = true) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: options)
    else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
}

struct Request {
    var title: String
    var subtitle = ""
    var body: NSAttributedString
    var raw: String?
    var preview: NSAttributedString
}

func preview(_ text: String) -> NSAttributedString {
    plain(String(text.prefix(600)), font: mono(previewSize), color: Palette.secondary)
}

func describeRequest() -> Request {
    switch toolName {
    case "Bash":
        let command = string("command")
        let short = shortenPaths(command)
        let body = NSMutableAttributedString()
        body.add("$ ", font: mono(codeSize, bold: true), color: Palette.accent)
        body.append(formatShell(short, indent: "    ", size: codeSize))
        return Request(
            title: tr("Run a command", "Запустить команду"), subtitle: string("description"), body: withHangingIndent(body, columns: 6),
            raw: short == command ? nil : command,
            preview: formatShell(String(short.prefix(600)), indent: "  ", size: previewSize)
        )
    case "Edit":
        let path = string("file_path"), old = string("old_string")
        var location = displayPath(path)
        if !old.isEmpty, let content = try? String(contentsOfFile: path, encoding: .utf8), let range = content.range(of: old) {
            location += ":\(content[..<range.lowerBound].filter { $0 == "\n" }.count + 1)"
        }
        if toolInput["replace_all"] as? Bool == true {
            location += tr(" · all occurrences", " · все вхождения")
        }
        let lines = diffLines(old: old, new: string("new_string"))
        return Request(title: tr("Edit a file", "Изменить файл"), subtitle: location, body: renderDiff(lines), preview: previewDiff(lines))
    case "Write":
        let path = string("file_path")
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        let lines = diffLines(old: existing ?? "", new: string("content"))
        let title = existing == nil ? tr("Create a file", "Создать файл") : tr("Overwrite a file", "Перезаписать файл")
        return Request(title: title, subtitle: displayPath(path), body: renderDiff(lines), preview: previewDiff(lines))
    case "NotebookEdit":
        let source = string("new_source")
        return Request(title: tr("Edit a notebook", "Изменить ноутбук"), subtitle: displayPath(string("notebook_path")), body: plain(source), preview: preview(source))
    case "Read":
        let path = displayPath(string("file_path"))
        return Request(title: tr("Read a file", "Прочитать файл"), subtitle: path, body: highlightJSON(json(toolInput)), preview: preview(path))
    case "WebFetch":
        let prompt = string("prompt")
        return Request(title: tr("Fetch a page", "Открыть страницу"), subtitle: string("url"), body: plain(prompt, font: .systemFont(ofSize: 13)), preview: preview(prompt))
    case "WebSearch":
        return Request(title: tr("Search the web", "Поиск в интернете"), subtitle: string("query"), body: highlightJSON(json(toolInput)), preview: preview(string("query")))
    default:
        let parts = toolName.components(separatedBy: "__")
        let title = parts.count == 3 && parts[0] == "mcp" ? "MCP · \(parts[1]) → \(parts[2])" : toolName
        return Request(title: title, body: highlightJSON(json(toolInput)), preview: preview(json(toolInput, pretty: false)))
    }
}

// Suggestions go back to Claude Code verbatim; this only labels them, across the shapes seen so far.
func describeSuggestion(_ suggestion: [String: Any]) -> String {
    if let rule = suggestion["rule"] as? String { return rule }
    switch suggestion["type"] as? String {
    case "addRules", "replaceRules":
        let rules = (suggestion["rules"] as? [[String: Any]] ?? []).map { rule in
            let tool = rule["toolName"] as? String ?? "?"
            guard let content = rule["ruleContent"] as? String else { return tool }
            return "\(tool)(\(content))"
        }
        return rules.joined(separator: ", ")
    case "addDirectories":
        return tr("access to ", "доступ к ") + (suggestion["directories"] as? [String] ?? []).joined(separator: ", ")
    case "setMode":
        return tr("mode ", "режим ") + (suggestion["mode"] as? String ?? "?")
    default:
        return json(suggestion)
    }
}

let alwaysTooltip = tr("Always allow: ", "Разрешать всегда: ") + suggestions.map(describeSuggestion).joined(separator: ", ")

// MARK: - Views

final class RoundedView: NSView {
    private let fill: NSColor

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = Palette.border.cgColor
    }
}

final class PillButton: NSButton {
    enum Style { case primary, secondary, plain }

    private let style: Style
    private let height: CGFloat

    init(_ title: String, style: Style, compact: Bool = false, target: AnyObject, action: Selector) {
        self.style = style
        height = compact ? 26 : 30
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = compact ? 7 : 8
        let color = switch style {
        case .primary: NSColor.white
        case .secondary: Palette.text
        case .plain: Palette.secondary
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 12.5 : 13, weight: .medium), .foregroundColor: color,
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + (style == .plain ? 8 : height - 6), height: height)
    }

    // The card never takes focus, so every click on it is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.75
        super.mouseDown(with: event)
        alphaValue = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .primary:
                layer?.backgroundColor = Palette.accent.cgColor
            case .secondary:
                layer?.backgroundColor = Palette.surface.cgColor
                layer?.borderColor = Palette.border.cgColor
                layer?.borderWidth = 1
            case .plain:
                layer?.backgroundColor = nil
            }
        }
    }
}

func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

// MARK: - Card

let cardWidth: CGFloat = 384
let cardPadding: CGFloat = 14
let cardIconSize: CGFloat = 36
let cardGap: CGFloat = 10

func processStart(_ pid: pid_t) -> TimeInterval {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let start = info.kp_proc.p_starttime
    return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
}

final class CardPanel: NSPanel {
    var onBackgroundClick: (() -> Void)?

    // Buttons swallow their own mouse-up, so one arriving here was a click on the card itself.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp, !(contentView?.hitTest(event.locationInWindow) is NSButton) {
            onBackgroundClick?()
        }
    }
}

final class Card: NSObject {
    let panel = CardPanel(
        contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let background = RoundedView(fill: Palette.background, radius: 14)
    private let countdown = CALayer()
    private var remaining = cardTimeout
    private var hovering = false
    private var ticker: Timer?
    private var reflow: Timer?

    init(_ request: Request) {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.onBackgroundClick = showDetails

        let textWidth = cardWidth - cardPadding * 2 - cardIconSize - 12
        let icon = NSImageView(image: appIcon())
        let close = PillButton("✕", style: .plain, compact: true, target: self, action: #selector(closeClicked))
        close.toolTip = tr("Answer in Claude", "Ответить в Claude")
        let titleRow = NSStackView()
        titleRow.addView(label(request.title, font: .systemFont(ofSize: 13, weight: .semibold), color: Palette.text), in: .leading)
        titleRow.addView(close, in: .trailing)
        let context = label([projectName, request.subtitle].filter { !$0.isEmpty }.joined(separator: " · "), font: .systemFont(ofSize: 12), color: Palette.secondary)
        let preview = NSTextField(labelWithAttributedString: request.preview)
        preview.maximumNumberOfLines = 4
        preview.lineBreakMode = .byCharWrapping
        preview.cell?.truncatesLastVisibleLine = true
        preview.preferredMaxLayoutWidth = textWidth
        preview.isHidden = request.preview.length == 0
        let text = NSStackView(views: [titleRow, context, preview])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(6, after: context)
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 12

        let buttons = NSStackView()
        buttons.spacing = 6
        buttons.addView(PillButton(tr("Details", "Подробнее"), style: .plain, compact: true, target: self, action: #selector(detailsClicked)), in: .leading)
        if !suggestions.isEmpty {
            let always = PillButton(tr("Always", "Всегда"), style: .secondary, compact: true, target: self, action: #selector(allowAlwaysClicked))
            always.toolTip = alwaysTooltip
            buttons.addView(always, in: .trailing)
        }
        buttons.addView(PillButton(tr("Deny", "Запретить"), style: .secondary, compact: true, target: self, action: #selector(denyClicked)), in: .trailing)
        buttons.addView(PillButton(tr("Allow", "Разрешить"), style: .primary, compact: true, target: self, action: #selector(allowClicked)), in: .trailing)

        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        panel.contentView = background
        background.layer?.addSublayer(countdown)
        background.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: cardIconSize),
            icon.heightAnchor.constraint(equalToConstant: cardIconSize),
            text.widthAnchor.constraint(equalToConstant: textWidth),
            titleRow.widthAnchor.constraint(equalTo: text.widthAnchor),
            context.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(equalToConstant: cardWidth - cardPadding * 2),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: cardPadding),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -cardPadding),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: cardPadding),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -cardPadding),
        ])
    }

    func show(animated: Bool) {
        let size = NSSize(width: cardWidth, height: panel.contentView?.fittingSize.height ?? 100)
        let frame = NSRect(origin: targetOrigin(height: size.height), size: size)
        defer {
            startCountdown()
            startReflow()
        }
        guard animated else {
            panel.setFrame(frame, display: true)
            return panel.orderFrontRegardless()
        }
        panel.setFrame(frame.offsetBy(dx: 24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    // Cards from parallel sessions stack oldest on top, so the one asking longest stays in the corner.
    private func targetOrigin(height: CGFloat) -> NSPoint {
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let mine = (processStart(getpid()), getpid())
        let above = otherCards().filter { ($0.start, $0.pid) < mine }.reduce(0) { $0 + $1.height + cardGap }
        return NSPoint(x: visible.maxX - cardWidth - cardGap, y: max(visible.minY, visible.maxY - cardGap - above - height))
    }

    private func otherCards() -> [(start: TimeInterval, pid: pid_t, height: CGFloat)] {
        let names = Set([NSRunningApplication.current.localizedName, ProcessInfo.processInfo.processName].compactMap { $0 })
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String, names.contains(owner),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  abs(bounds.width - cardWidth) < 1
            else { return nil }
            return (processStart(pid), pid, bounds.height)
        }
    }

    // When a card above goes away, slide up into the freed space.
    private func startReflow() {
        reflow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let origin = targetOrigin(height: panel.frame.height)
            guard abs(origin.y - panel.frame.minY) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.animator().setFrame(NSRect(origin: origin, size: self.panel.frame.size), display: true)
            }
        }
    }

    func stopCountdown() {
        ticker?.invalidate()
        ticker = nil
    }

    // Paused while the pointer is over the card, so it never vanishes mid-read.
    private func startCountdown() {
        let step = 1.0 / 30
        ticker = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !hovering { remaining -= step }
            guard remaining > 0 else { return dismiss() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            countdown.frame = CGRect(x: 0, y: 0, width: background.bounds.width * remaining / cardTimeout, height: 2)
            countdown.opacity = 0.7
            background.effectiveAppearance.performAsCurrentDrawingAppearance {
                self.countdown.backgroundColor = Palette.accent.cgColor
            }
            CATransaction.commit()
        }
    }

    func dismiss() {
        stopCountdown()
        reflow?.invalidate()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 24, dy: 0), display: true)
        }, completionHandler: { leaveToClaude() })
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { hovering = true }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hovering = false }

    @objc func allowClicked() { allow() }
    @objc func allowAlwaysClicked() { allowAlways() }
    @objc func denyClicked() { deny() }
    @objc func detailsClicked() { showDetails() }
    @objc func closeClicked() { leaveToClaude() }
}

// MARK: - Details window

final class DetailsWindow: NSObject, NSWindowDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }

    init(_ request: Request) {
        super.init()
        window.title = "Claude Code · \(projectName) · \(toolName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Palette.background
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 260)
        window.delegate = self

        let title = label(request.title, font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.text)
        let context = label([projectName, request.subtitle].filter { !$0.isEmpty }.joined(separator: " · "), font: .systemFont(ofSize: 12.5), color: Palette.secondary)

        let card = RoundedView(fill: Palette.surface, radius: 10)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        card.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.textStorage?.setAttributedString(request.body)
        textView.toolTip = request.raw
        // Return should allow, so nothing that takes text may hold the initial focus.
        window.initialFirstResponder = textView

        let buttons = NSStackView()
        buttons.spacing = 8
        if !suggestions.isEmpty {
            let always = PillButton(tr("Always allow", "Разрешать всегда"), style: .secondary, target: self, action: #selector(allowAlwaysClicked))
            always.toolTip = alwaysTooltip
            buttons.addView(always, in: .trailing)
        }
        buttons.addView(PillButton(tr("Deny", "Запретить"), style: .secondary, target: self, action: #selector(denyClicked)), in: .trailing)
        buttons.addView(PillButton(tr("Allow", "Разрешить"), style: .primary, target: self, action: #selector(allowClicked)), in: .trailing)

        let rows: [NSView] = [title, context, card, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 4
        stack.setCustomSpacing(14, after: context)
        stack.setCustomSpacing(14, after: card)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 20, bottom: 18, right: 20)
        stack.wantsLayer = true
        window.contentView = stack
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        for row in rows {
            row.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        }
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        fitHeight(to: card)
    }

    private func fitHeight(to card: NSView) {
        window.layoutIfNeeded()
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height - layoutManager.extraLineFragmentUsedRect.height
        let textHeight = usedHeight + textView.textContainerInset.height * 2 + 2
        let contentHeight = window.contentRect(forFrameRect: window.frame).height + textHeight - card.frame.height
        window.setContentSize(NSSize(width: window.frame.width, height: min(720, max(240, contentHeight))))
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        switch event.keyCode {
        case 36, 76: allow() // Return, keypad Enter
        case 53: deny() // Escape
        default: return event
        }
    }

    @objc func allowClicked() { allow() }
    @objc func allowAlwaysClicked() { allowAlways() }
    @objc func denyClicked() { deny() }

    func windowWillClose(_ notification: Notification) { leaveToClaude() }
}

// MARK: - Settled elsewhere

// Claude Code holds back its own prompt while the hook runs, so the card steps aside once the chat is in view
// or the request got settled some other way.
final class SettlementWatch {
    private let transcript = input["transcript_path"] as? String
    private var toolUseID = input["tool_use_id"] as? String
    private var offset: UInt64

    init() {
        offset = (try? FileManager.default.attributesOfItem(atPath: transcript ?? "")[.size] as? UInt64) ?? 0
        toolUseID = toolUseID ?? findToolUseID()
    }

    func isSettled() -> Bool {
        if isOpenInFrontClaudeApp() || getppid() == 1 { return true }
        var output = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
        if poll(&output, 1, 0) > 0, output.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
        toolUseID = toolUseID ?? findToolUseID()
        guard let transcript, let toolUseID, let handle = FileHandle(forReadingAtPath: transcript) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        // Re-read a short tail next time in case the id was split across two reads.
        offset += UInt64(max(0, data.count - 128))
        return String(decoding: data, as: UTF8.self).contains("\"tool_use_id\":\"\(toolUseID)\"")
    }

    // Older Claude Code versions leave tool_use_id out of the hook input; the call itself is already in the transcript.
    private func findToolUseID() -> String? {
        guard let transcript, let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: offset > window ? offset - window : 0)
        let wanted = json(toolInput, pretty: false)
        let tail = handle.readData(ofLength: Int(min(offset, window)))
        for line in String(decoding: tail, as: UTF8.self).split(separator: "\n").reversed() where line.contains("\"tool_use\"") {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == toolName {
                if let blockInput = block["input"], json(blockInput, pretty: false) == wanted { return block["id"] as? String }
            }
        }
        return nil
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let appearance = environment["PERMISSION_POPUP_APPEARANCE"] {
    app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
}

let request = describeRequest()
let card = Card(request)
var details: DetailsWindow?

func makeDetails() -> DetailsWindow {
    if let details { return details }
    let created = DetailsWindow(request)
    details = created
    NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: created.handleKey)
    created.window.center()
    return created
}

func showDetails() {
    card.stopCountdown()
    card.panel.orderOut(nil)
    NSApp.activate(ignoringOtherApps: true)
    makeDetails().window.makeKeyAndOrderFront(nil)
    Timer.scheduledTimer(withTimeInterval: windowTimeout, repeats: false) { _ in leaveToClaude() }
}

// Renders a window to a PNG so the look can be checked without screen-recording access.
func snapshot(_ window: NSWindow, to path: String) {
    guard let view = window.contentView, let layer = view.layer else { return }
    let scale = window.backingScaleFactor
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
    context.scaleBy(x: scale, y: scale)
    if window.isOpaque {
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(Palette.background.cgColor)
        }
        context.fill(view.bounds)
    }
    layer.render(in: context)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let snapshotPath = environment["PERMISSION_POPUP_SNAPSHOT"] {
    card.show(animated: false)
    makeDetails().window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        snapshot(card.panel, to: snapshotPath + "-card.png")
        if let details { snapshot(details.window, to: snapshotPath + "-window.png") }
        exit(0)
    }
} else {
    card.show(animated: true)
    let watch = SettlementWatch()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        guard watch.isSettled() else { return }
        timer.invalidate()
        if card.panel.isVisible { card.dismiss() } else { leaveToClaude() }
    }
}
app.run()
