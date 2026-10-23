import AppKit
import Carbon.HIToolbox

// Claude Code PermissionRequest hook: a notification-style card with Allow/Deny, the full request in a window on demand.
// System notifications hide action buttons behind an "Options" menu, hence a card of our own.
// Printing nothing (closed, timeout) leaves the decision to Claude Code's own prompt.

let environment = ProcessInfo.processInfo.environment
// An unanswered card hands the question back to Claude Code's own prompt instead of holding the session.
let cardTimeout = TimeInterval(environment["PERMISSION_POPUP_TIMEOUT"] ?? "") ?? 15
// Stays under the 600 s hook timeout in settings.json.
let windowTimeout: TimeInterval = 540
let grantMinutes = Double(environment["PERMISSION_POPUP_GRANT_MINUTES"] ?? "") ?? 10
let soundEnabled = environment["PERMISSION_POPUP_SOUND"] != "0"
// Their answers are richer than allow/deny, so only Claude Code's own UI can collect them.
let passthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
let hostSession = environment["CLAUDE_CODE_HOST_SESSION_ID"]

enum Corner: String {
    case topRight = "top-right", topLeft = "top-left", bottomRight = "bottom-right", bottomLeft = "bottom-left"

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topRight || self == .topLeft }
}

let corner = Corner(rawValue: environment["PERMISSION_POPUP_CORNER"] ?? "") ?? .topRight

// The chat open in the frontmost Claude app already shows Claude Code's own prompt; a card would only repeat it.
func isOpenInFrontClaudeApp() -> Bool {
    guard let hostSession, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop"
    else { return false }
    // Undocumented app state: if its shape changes, the card just keeps showing.
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    guard let data = try? Data(contentsOf: url),
          let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let panes = ((config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])?["desktop-frame.paneStore.v1"]
    else { return false }
    return json(panes, pretty: false).contains("\"\(hostSession)\"")
}

let input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
let toolName = input["tool_name"] as? String ?? ""
if toolName.isEmpty || passthroughTools.contains(toolName) || isOpenInFrontClaudeApp() { exit(0) }

let toolInput = input["tool_input"] as? [String: Any] ?? [:]
let suggestions = input["permission_suggestions"] as? [[String: Any]] ?? []
let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
let projectName = (cwd as NSString).lastPathComponent
let paths = PathShortener(cwd: cwd, home: NSHomeDirectory())
let danger = dangerLabel(toolName: toolName, input: toolInput)

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

func allowForAWhile() -> Never {
    let rule = suggestedRules.first { PermissionRule($0) != nil }
    GrantStore.standard.add(Grant(
        cwd: cwd, rule: rule, toolName: toolName, input: rule == nil ? json(toolInput, pretty: false) : nil,
        expires: Date().addingTimeInterval(grantMinutes * 60)
    ))
    allow()
}

// A bare deny stops Claude like the built-in "No" does; a reason lets it adapt and continue.
func deny(reason: String = "") -> Never {
    let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        respond(["behavior": "deny", "message": "The user denied this tool call.", "interrupt": true])
    }
    respond(["behavior": "deny", "message": text])
}

func leaveToClaude() -> Never {
    exit(0)
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

let suggestedRules = suggestions.flatMap { describeSuggestion($0).components(separatedBy: ", ") }
let alwaysTooltip = tr("Always allow: ", "Разрешать всегда: ") + suggestions.map(describeSuggestion).joined(separator: ", ")
let grantTooltip = suggestedRules.first { PermissionRule($0) != nil }.map {
    tr("For this project, calls matching ", "В этом проекте вызовы под правило ") + $0
} ?? tr("For this project, exactly this call", "В этом проекте ровно этот вызов")

// Dangerous requests never ride on a grant, they always ask.
if danger == nil, GrantStore.standard.allows(toolName: toolName, input: toolInput, cwd: cwd, home: NSHomeDirectory()) {
    allow()
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
    static let danger = dynamicColor(light: 0xB3261E, dark: 0xF2867A)
    static let dangerBackground = dynamicColor(light: 0xFBEDEA, dark: 0x3A2523)
    static let dangerBorder = dynamicColor(light: 0xE8B4AC, dark: 0x6B3A35)
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

func render(_ segments: [ShellSegment], size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for segment in segments {
        let (color, bold): (NSColor, Bool) = switch segment.token {
        case .plain: (Palette.text, false)
        case .command: (Palette.text, true)
        case .keyword: (Palette.accent, false)
        case .op: (Palette.accent, true)
        case .variable: (Palette.variable, false)
        case .string: (Palette.string, false)
        case .flag: (Palette.secondary, false)
        case .redirect, .comment: (Palette.tertiary, false)
        }
        out.add(segment.text, font: mono(size, bold: bold), color: color)
    }
    return out
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

func renderSummary(_ input: [String: Any], size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (index, field) in summarize(input).enumerated() {
        out.add((index > 0 ? "\n" : "") + field.key + ": ", font: mono(size), color: Palette.variable)
        out.add(field.value, font: mono(size), color: Palette.text)
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
        let short = paths.shorten(command)
        let body = NSMutableAttributedString()
        body.add("$ ", font: mono(codeSize, bold: true), color: Palette.accent)
        body.append(render(formatShell(short, indent: "    "), size: codeSize))
        return Request(
            title: tr("Run a command", "Запустить команду"), subtitle: string("description"), body: withHangingIndent(body, columns: 6),
            raw: short == command ? nil : command,
            preview: render(formatShell(String(short.prefix(600)), indent: "  "), size: previewSize)
        )
    case "Edit":
        let path = string("file_path"), old = string("old_string")
        var location = paths.display(path)
        if !old.isEmpty, let content = try? String(contentsOfFile: path, encoding: .utf8), let range = content.range(of: old) {
            location += ":\(content[..<range.lowerBound].filter { $0 == "\n" }.count + 1)"
        }
        if toolInput["replace_all"] as? Bool == true {
            location += tr(" · all occurrences", " · все вхождения")
        }
        let lines = diffLines(old: old, new: string("new_string"))
        return Request(title: tr("Edit a file", "Изменить файл"), subtitle: location, body: renderDiff(lines), preview: previewDiff(lines))
    case "Write":
        let path = string("file_path"), content = string("content")
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        let lines = diffLines(old: existing ?? "", new: content)
        let title = existing == nil ? tr("Create a file", "Создать файл") : tr("Overwrite a file", "Перезаписать файл")
        let count = splitLines(content).count
        let subtitle = paths.display(path) + tr(" · \(count) lines", " · строк: \(count)")
        return Request(title: title, subtitle: subtitle, body: renderDiff(lines), preview: previewDiff(lines))
    case "NotebookEdit":
        let source = string("new_source")
        return Request(title: tr("Edit a notebook", "Изменить ноутбук"), subtitle: paths.display(string("notebook_path")), body: plain(source), preview: preview(source))
    case "Read":
        let path = paths.display(string("file_path"))
        return Request(title: tr("Read a file", "Прочитать файл"), subtitle: path, body: renderSummary(toolInput, size: codeSize), preview: preview(path))
    case "WebFetch":
        let prompt = string("prompt")
        return Request(title: tr("Fetch a page", "Открыть страницу"), subtitle: string("url"), body: plain(prompt, font: .systemFont(ofSize: 13)), preview: preview(prompt))
    case "WebSearch":
        return Request(title: tr("Search the web", "Поиск в интернете"), subtitle: string("query"), body: renderSummary(toolInput, size: codeSize), preview: preview(string("query")))
    default:
        let parts = toolName.components(separatedBy: "__")
        let title = parts.count == 3 && parts[0] == "mcp" ? "MCP · \(parts[1]) → \(parts[2])" : toolName
        return Request(title: title, body: renderSummary(toolInput, size: codeSize), preview: renderSummary(toolInput, size: previewSize))
    }
}

// MARK: - Views

final class RoundedView: NSView {
    private let fill: NSColor
    private let border: NSColor

    init(fill: NSColor, radius: CGFloat, border: NSColor = Palette.border) {
        self.fill = fill
        self.border = border
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
        layer?.borderColor = border.cgColor
    }
}

final class PillButton: NSButton {
    enum Style { case primary, secondary, plain, danger }

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
        case .danger: Palette.danger
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
        guard isEnabled else { return super.mouseDown(with: event) }
        alphaValue = 0.75
        super.mouseDown(with: event)
        alphaValue = 1
    }

    func setArmed(_ armed: Bool) {
        isEnabled = armed
        alphaValue = armed ? 1 : 0.45
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
            case .secondary, .danger:
                layer?.backgroundColor = Palette.surface.cgColor
                layer?.borderColor = (style == .danger ? Palette.dangerBorder : Palette.border).cgColor
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

final class LinkLabel: NSTextField {
    var onClick: (() -> Void)?
}

// "project · subtitle", with the project name linking to its chat in the Claude desktop app when there is one.
func contextLabel(subtitle: String, size: CGFloat) -> LinkLabel {
    let text = NSMutableAttributedString()
    let link = hostSession.flatMap { URL(string: "claude://claude.ai/epitaxy/\($0)") }
    text.append(NSAttributedString(string: projectName, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: link == nil ? .regular : .medium),
        .foregroundColor: link == nil ? Palette.secondary : Palette.accent,
    ]))
    if !subtitle.isEmpty {
        text.append(NSAttributedString(string: " · " + subtitle, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Palette.secondary]))
    }
    let field = LinkLabel(labelWithAttributedString: text)
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if let link {
        field.toolTip = tr("Open this chat in Claude", "Открыть этот чат в Claude")
        field.onClick = { NSWorkspace.shared.open(link) }
    }
    return field
}

func dangerRow(size: CGFloat) -> NSTextField? {
    danger.map { label(tr("Careful: ", "Осторожно: ") + $0, font: .systemFont(ofSize: size, weight: .semibold), color: Palette.danger) }
}

let titlePrefix = danger == nil ? "" : "⚠ "

// MARK: - Global shortcuts

// ⌃⌥Y allows, ⌃⌥N denies, ⌃⌥D opens the details; only the top card holds them, so each press answers one request.
final class HotKeys {
    enum Key: UInt32 { case allow, deny, details }

    var onKey: ((Key) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func setActive(_ active: Bool) {
        if active, refs.isEmpty { register() }
        if !active, !refs.isEmpty { unregister() }
    }

    private func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                if let context, let key = Key(rawValue: id.id) {
                    Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().onKey?(key)
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        for (key, code) in [(Key.allow, kVK_ANSI_Y), (.deny, kVK_ANSI_N), (.details, kVK_ANSI_D)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5050_5550), id: key.rawValue)
            if RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}

// MARK: - Menu bar

// Only the top card shows the badge, with the number of requests waiting across sessions.
final class MenuBarBadge: NSObject {
    private var item: NSStatusItem?
    private let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func update(active: Bool, count: Int) {
        guard active else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        item.button?.title = " \(count)"
        summary.title = tr("Waiting for an answer: \(count)", "Ждут ответа: \(count)")
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Claude Code")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(summary)
        menu.addItem(.separator())
        let show = NSMenuItem(title: tr("Show the oldest request", "Показать самый старый запрос"), action: #selector(showClicked), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        item.menu = menu
        self.item = item
        return item
    }

    @objc func showClicked() { showDetails() }
}

// MARK: - Card

let cardWidth: CGFloat = 384
let cardPadding: CGFloat = 14
let cardIconSize: CGFloat = 36
let cardGap: CGFloat = 10
// Long enough that a click aimed at whatever sat under the card can't land on its buttons.
let armDelay: TimeInterval = 0.6

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
        guard event.type == .leftMouseUp else { return }
        let hit = contentView?.hitTest(event.locationInWindow)
        if let link = hit as? LinkLabel, let onClick = link.onClick { return onClick() }
        if !(hit is NSButton) { onBackgroundClick?() }
    }
}

final class Card: NSObject {
    let panel = CardPanel(
        contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let background = RoundedView(
        fill: danger == nil ? Palette.background : Palette.dangerBackground, radius: 14,
        border: danger == nil ? Palette.border : Palette.dangerBorder
    )
    private let countdown = CALayer()
    private var decisionButtons: [PillButton] = []
    private var remaining = cardTimeout
    private var hovering = false
    private var shownAt: Date?
    private var enteredAfterShow = false
    private var armed = false
    private var topSince: Date?
    private var ticker: Timer?
    private var reflow: Timer?
    private let hotKeys = HotKeys()
    private let badge = MenuBarBadge()

    init(_ request: Request) {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.onBackgroundClick = showDetails
        hotKeys.onKey = { [weak self] in self?.hotKey($0) }

        let textWidth = cardWidth - cardPadding * 2 - cardIconSize - 12
        let icon = NSImageView(image: appIcon())
        let close = PillButton("✕", style: .plain, compact: true, target: self, action: #selector(closeClicked))
        close.toolTip = tr("Answer in Claude", "Ответить в Claude")
        let titleRow = NSStackView()
        titleRow.addView(label(titlePrefix + request.title, font: .systemFont(ofSize: 13, weight: .semibold), color: Palette.text), in: .leading)
        titleRow.addView(close, in: .trailing)
        let context = contextLabel(subtitle: request.subtitle, size: 12)
        let preview = NSTextField(labelWithAttributedString: request.preview)
        preview.maximumNumberOfLines = 4
        preview.lineBreakMode = .byCharWrapping
        preview.cell?.truncatesLastVisibleLine = true
        preview.preferredMaxLayoutWidth = textWidth
        preview.isHidden = request.preview.length == 0
        let text = NSStackView(views: [titleRow] + [dangerRow(size: 12)].compactMap { $0 } + [context, preview])
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
        if !suggestions.isEmpty, danger == nil {
            let always = PillButton(tr("Always", "Всегда"), style: .secondary, compact: true, target: self, action: #selector(allowAlwaysClicked))
            always.toolTip = alwaysTooltip
            decisionButtons.append(always)
        }
        let deny = PillButton(tr("Deny", "Запретить"), style: .secondary, compact: true, target: self, action: #selector(denyClicked))
        deny.toolTip = "⌃⌥N"
        let allow = PillButton(tr("Allow", "Разрешить"), style: danger == nil ? .primary : .danger, compact: true, target: self, action: #selector(allowClicked))
        allow.toolTip = danger == nil ? "⌃⌥Y" : nil
        decisionButtons += [deny, allow]
        decisionButtons.forEach {
            $0.setArmed(false)
            buttons.addView($0, in: .trailing)
        }

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
        let frame = NSRect(origin: layout(height: size.height).origin, size: size)
        shownAt = Date()
        defer {
            startCountdown()
            startReflow()
        }
        guard animated else {
            panel.setFrame(frame, display: true)
            return panel.orderFrontRegardless()
        }
        panel.setFrame(frame.offsetBy(dx: corner.isRight ? 24 : -24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        if soundEnabled { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    func arm() {
        armed = true
        decisionButtons.forEach { $0.setArmed(true) }
    }

    // Cards from parallel sessions stack oldest first from the corner, so the one asking longest stays put.
    private func layout(height: CGFloat) -> (origin: NSPoint, isTop: Bool, count: Int) {
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let mine = (processStart(getpid()), getpid())
        let others = otherCards()
        let before = others.filter { ($0.start, $0.pid) < mine }.reduce(0) { $0 + $1.height + cardGap }
        let x = corner.isRight ? visible.maxX - cardWidth - cardGap : visible.minX + cardGap
        let y = corner.isTop
            ? max(visible.minY, visible.maxY - cardGap - before - height)
            : min(visible.maxY - height, visible.minY + cardGap + before)
        return (NSPoint(x: x, y: y), before == 0, others.count + 1)
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

    // When a card ahead goes away, slide into the freed space and take over the shortcuts and the badge.
    private func startReflow() {
        reflow = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let layout = layout(height: panel.frame.height)
            let isTop = layout.isTop && panel.isVisible
            topSince = isTop ? topSince ?? Date() : nil
            hotKeys.setActive(isTop)
            badge.update(active: isTop, count: layout.count)
            guard abs(layout.origin.y - panel.frame.minY) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.animator().setFrame(NSRect(origin: layout.origin, size: self.panel.frame.size), display: true)
            }
        }
    }

    func stepAside() {
        stopCountdown()
        hotKeys.setActive(false)
        badge.update(active: false, count: 0)
        panel.orderOut(nil)
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
            if !armed, enteredAfterShow, let shownAt, Date().timeIntervalSince(shownAt) >= armDelay { arm() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            countdown.frame = CGRect(x: 0, y: 0, width: background.bounds.width * remaining / cardTimeout, height: 2)
            countdown.opacity = 0.7
            background.effectiveAppearance.performAsCurrentDrawingAppearance {
                self.countdown.backgroundColor = (danger == nil ? Palette.accent : Palette.danger).cgColor
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
            panel.animator().setFrame(panel.frame.offsetBy(dx: corner.isRight ? 24 : -24, dy: 0), display: true)
        }, completionHandler: { leaveToClaude() })
    }

    private func hotKey(_ key: HotKeys.Key) {
        // A press meant for the card that just left must not answer the one sliding into its place.
        guard let topSince, Date().timeIntervalSince(topSince) >= armDelay else { return NSSound.beep() }
        switch key {
        case .allow:
            if danger == nil { allow() }
            NSSound.beep()
        case .deny: deny()
        case .details: showDetails()
        }
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hovering = true
        if shownAt != nil { enteredAfterShow = true }
    }

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
    private let reason = NSTextField()

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
        window.minSize = NSSize(width: 520, height: 280)
        window.delegate = self

        let title = label(titlePrefix + request.title, font: .systemFont(ofSize: 17, weight: .semibold), color: Palette.text)
        let context = contextLabel(subtitle: request.subtitle, size: 12.5)
        let contextClick = NSClickGestureRecognizer(target: self, action: #selector(contextClicked))
        context.addGestureRecognizer(contextClick)

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

        let reasonCard = RoundedView(fill: Palette.surface, radius: 8)
        reason.isBezeled = false
        reason.drawsBackground = false
        reason.focusRingType = .none
        reason.font = .systemFont(ofSize: 13)
        reason.textColor = Palette.text
        reason.cell?.isScrollable = true
        reason.cell?.wraps = false
        reason.placeholderAttributedString = NSAttributedString(
            string: tr("Reason to deny, Claude will see it (Return denies)", "Причина отказа, её увидит Claude (Enter — запретить)"),
            attributes: [.foregroundColor: Palette.tertiary, .font: NSFont.systemFont(ofSize: 13)]
        )
        reason.translatesAutoresizingMaskIntoConstraints = false
        reasonCard.addSubview(reason)

        let buttons = NSStackView()
        buttons.spacing = 8
        if danger == nil {
            let grant = PillButton(tr("Allow for \(Int(grantMinutes)) min", "Разрешить на \(Int(grantMinutes)) мин"), style: .secondary, target: self, action: #selector(allowForAWhileClicked))
            grant.toolTip = grantTooltip
            buttons.addView(grant, in: .leading)
            if !suggestions.isEmpty {
                let always = PillButton(tr("Always allow", "Разрешать всегда"), style: .secondary, target: self, action: #selector(allowAlwaysClicked))
                always.toolTip = alwaysTooltip
                buttons.addView(always, in: .trailing)
            }
        }
        buttons.addView(PillButton(tr("Deny", "Запретить"), style: .secondary, target: self, action: #selector(denyClicked)), in: .trailing)
        buttons.addView(PillButton(tr("Allow", "Разрешить"), style: danger == nil ? .primary : .danger, target: self, action: #selector(allowClicked)), in: .trailing)

        let rows: [NSView] = [title] + [dangerRow(size: 12.5)].compactMap { $0 } + [context, card, reasonCard, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 4
        stack.setCustomSpacing(14, after: context)
        stack.setCustomSpacing(10, after: card)
        stack.setCustomSpacing(14, after: reasonCard)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 20, bottom: 18, right: 20)
        stack.wantsLayer = true
        window.contentView = stack
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            reason.leadingAnchor.constraint(equalTo: reasonCard.leadingAnchor, constant: 10),
            reason.trailingAnchor.constraint(equalTo: reasonCard.trailingAnchor, constant: -10),
            reason.centerYAnchor.constraint(equalTo: reasonCard.centerYAnchor),
            reasonCard.heightAnchor.constraint(equalToConstant: 32),
        ])
        for row in rows {
            row.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        }
        for row in [card, reasonCard, buttons] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        fitHeight(to: card)
    }

    private func fitHeight(to card: NSView) {
        window.layoutIfNeeded()
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height - layoutManager.extraLineFragmentUsedRect.height
        let textHeight = usedHeight + textView.textContainerInset.height * 2 + 2
        let contentHeight = window.contentRect(forFrameRect: window.frame).height + textHeight - card.frame.height
        window.setContentSize(NSSize(width: window.frame.width, height: min(720, max(260, contentHeight))))
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if reason.currentEditor() != nil { deny(reason: reason.stringValue) }
            if danger != nil { NSSound.beep() } else { allow() }
        case 53: // Escape
            deny(reason: reason.stringValue)
        default:
            return event
        }
        return nil
    }

    @objc func allowClicked() { allow() }
    @objc func allowAlwaysClicked() { allowAlways() }
    @objc func allowForAWhileClicked() { allowForAWhile() }
    @objc func denyClicked() { deny(reason: reason.stringValue) }
    @objc func contextClicked(_ sender: NSClickGestureRecognizer) { (sender.view as? LinkLabel)?.onClick?() }

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
// Launched by the frontmost Claude, the app would otherwise become active and swallow what the user is typing.
// Only the details window, opened by a click, needs keyboard focus.
app.setActivationPolicy(.prohibited)
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
    card.stepAside()
    NSApp.setActivationPolicy(.accessory)
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
    card.arm()
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
