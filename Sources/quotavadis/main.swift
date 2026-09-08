import Foundation
import QuotaCore

// quotavadis — the terminal view of the same numbers the menu bar app shows.
//
//   quotavadis                 table of every tool
//   quotavadis --json          snapshots as JSON
//   quotavadis --watch [sec]   refresh in place (default 60 s)
//   quotavadis --provider claude|codex|cursor|gemini
//   quotavadis cost            30-day cost & tokens (--fast-2x prices Codex Fast mode at 2x)
//   quotavadis raw | profile | keychain | claude-web | codex-cli   diagnostics
//   --web forces the claude.ai web session, --no-color disables ANSI colours

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func value(after name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
    return args[i + 1]
}
let color = !flag("--no-color") && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func tint(_ pct: Double) -> String { pct < 50 ? "32" : pct < 80 ? "33" : "31" }
func bar(_ pct: Double, width: Int = 20) -> String {
    let filled = Int((min(100, max(0, pct)) / 100 * Double(width)).rounded())
    return paint(String(repeating: "█", count: filled), tint(pct)) + paint(String(repeating: "░", count: width - filled), "90")
}
let source: UsageService.ClaudeSource = flag("--web") ? .web : .automatic
// "gemini" is the name shown everywhere now; the raw value is still "antigravity" (see ProviderID), so
// accept both spellings on the command line.
let only: ProviderID? = value(after: "--provider").flatMap { ProviderID(rawValue: $0 == "gemini" ? "antigravity" : $0) }
let enabled: Set<ProviderID> = only.map { [$0] } ?? Set(ProviderID.allCases)

if flag("--help") || flag("-h") || args.first == "help" {
    print("""
    quotavadis — Claude Code, Codex, Cursor and Gemini limits in the terminal

      quotavadis                  table of every tool
      quotavadis --json           snapshots as JSON
      quotavadis --watch [sec]    refresh in place (default 60 s)
      quotavadis --provider NAME  claude | codex | cursor | gemini
      quotavadis cost [--fast-2x] 30-day cost & token estimates
      quotavadis raw | profile | keychain | claude-web | codex-cli
      --web        use the claude.ai web session instead of the Claude Code login
      --no-color   plain output (NO_COLOR is honoured too)
    """)
    exit(0)
}

let command = args.first(where: { !$0.hasPrefix("-") }) ?? ""

if command == "cost" || flag("--cost") {
    let started = Date()
    let reports = await CostService().refresh(enabled: enabled, fastModeAt2x: flag("--fast-2x"))
    for id in ProviderID.allCases where enabled.contains(id) {
        guard let r = reports[id] else { print("\(id.displayName): no cost data"); continue }
        let today = r.today
        print(paint(id.displayName, "1") + ": today $\(String(format: "%.2f", today?.costUSD ?? 0)) · \(today?.tokens.total ?? 0) tok · 30d $\(String(format: "%.2f", r.totalCostUSD)) · \(r.totalTokens) tok")
        for m in r.byModel.prefix(4) { print("   \(m.id.padding(toLength: 28, withPad: " ", startingAt: 0)) $\(String(format: "%8.2f", m.costUSD))  \(m.tokens.total) tok  \(m.requests) req") }
        for pr in r.byProject.prefix(3) { print("   proj \(pr.id)  $\(String(format: "%.2f", pr.costUSD))") }
        print("   last 7 days: " + r.days.suffix(7).map { String(format: "%.0f", $0.costUSD) }.joined(separator: " "))
    }
    print(paint(String(format: "(%.1fs)", Date().timeIntervalSince(started)), "90"))
    exit(0)
}

if command == "claude-web" || flag("--claude-web") {
    for (name, data) in try await DebugProbes.claudeWeb() {
        print("=== \(name)")
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: pretty, as: UTF8.self).prefix(1600))
        } else { print(String(decoding: data, as: UTF8.self).prefix(300)) }
    }
    exit(0)
}
if command == "codex-cli" || flag("--codex-cli") {
    let result = try await CodexCLI.readRateLimits()
    print(result.map { String(decoding: $0, as: UTF8.self) } ?? "codex CLI not found")
    exit(0)
}
if command == "keychain" || flag("--keychain") {
    for e in ClaudeCredentials.keychainEntries() {
        print("\(e.service)  created \(e.created?.formatted() ?? "?")  modified \(e.modified?.formatted() ?? "?")")
    }
    exit(0)
}
if command == "profile" || flag("--profile") {
    for (name, data) in await DebugProbes.profiles() {
        print("=== \(name)")
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: pretty, as: UTF8.self))
        } else { print(String(decoding: data, as: UTF8.self)) }
    }
    exit(0)
}
if command == "raw" || flag("--raw") {
    for fetcher in UsageService.defaultFetchers(claudeSource: source) where fetcher.isAvailable() && enabled.contains(fetcher.provider) {
        print("=== \(fetcher.provider.displayName)")
        do {
            let data = try await fetcher.fetchRaw()
            let obj = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: pretty, as: UTF8.self))
        } catch { print("ERROR \(error)") }
    }
    exit(0)
}

let service = UsageService(fetchers: UsageService.defaultFetchers(claudeSource: source))

func render(_ states: [String: ProviderState]) -> String {
    var out = ""
    let order = ProviderID.allCases.flatMap { p in states.keys.filter { $0 == p.rawValue || $0.hasPrefix(p.rawValue + ":") || $0.hasPrefix(p.rawValue + "-web") }.sorted() }
    for id in order {
        guard let state = states[id] else { continue }
        let provider = ProviderID(rawValue: id.split(separator: ":").first.map { String($0).replacingOccurrences(of: "-web", with: "") } ?? id)
        let name = id.hasPrefix("claude-web") ? "Claude (claude.ai session)" : (provider?.displayName ?? id)
        switch state {
        case .unavailable:
            out += paint(name, "1") + paint("  not installed\n", "90")
        case .failed(let error, let last):
            out += paint(name, "1") + paint("  ⚠ \(error.localizedDescription)\n", "33")
            if let last { out += renderSnapshot(last) }
        case .fresh(let s):
            let who = [s.organization, s.plan, s.seat].compactMap { $0 }.joined(separator: " · ")
            out += paint(name, "1") + (who.isEmpty ? "" : paint("  \(who)", "90")) + "\n"
            out += renderSnapshot(s)
        }
    }
    return out
}

func renderSnapshot(_ s: UsageSnapshot) -> String {
    var out = ""
    for w in s.windows where w.prominent || s.overviewWindows.contains(where: { $0.id == w.id }) {
        let reset = w.resetsAt.map { "  " + paint($0.resetLabel(), "90") } ?? ""
        out += "  \(w.title.padding(toLength: 22, withPad: " ", startingAt: 0)) \(bar(w.usedPercent)) \(paint(String(format: "%3.0f%%", w.usedPercent), tint(w.usedPercent)))\(reset)\n"
    }
    for c in s.credits where c.used > 0 || c.limit != nil {
        let limit = c.limit.map { String(format: " / %.2f", $0) } ?? ""
        let over = c.limit.map { c.used >= $0 } ?? false
        out += "  \(c.title.padding(toLength: 22, withPad: " ", startingAt: 0)) " + paint(String(format: "$%.2f%@ %@", c.used, limit, c.currency), over ? "31" : "0") + "\n"
    }
    if let resets = s.resetCreditsAvailable { out += "  \("Resets available".padding(toLength: 22, withPad: " ", startingAt: 0)) \(resets)\n" }
    return out
}

if flag("--json") {
    let states = await service.refresh(enabled: enabled)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(states.keys.sorted().compactMap { states[$0]?.snapshot }), as: UTF8.self))
    exit(0)
}

if flag("--watch") {
    let interval = Double(value(after: "--watch") ?? "60") ?? 60
    while true {
        let states = await service.refresh(enabled: enabled)
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        print(paint("QuotaVadis · \(Date().formatted(date: .omitted, time: .shortened)) · every \(Int(interval)) s (Claude at most every 5 min)", "90"))
        print(render(states), terminator: "")
        try await Task.sleep(for: .seconds(interval))
    }
}

print(render(await service.refresh(enabled: enabled)), terminator: "")
