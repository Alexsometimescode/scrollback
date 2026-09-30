// Scrollback - menu bar control for the 5/15 collection.
//
// Layout follows the HIG idea of clarity before chrome: whatever needs your
// attention is the first and largest thing, with exactly one action next to
// it. Everything you only occasionally touch folds into accordions below.
//
// All wording and all health logic come from scroll_status.sh and the collect
// scripts. This app renders; it does not decide.

import AppKit
import SwiftUI
import UserNotifications

/// Where the scripts live. The app is built into Scrollback/Scrollback.app, so the
/// checkout is two directories up from the executable. Falls back to the app's
/// own folder if someone moves the binary.
let scrollHome: String = {
    // Walk up from the executable and take the first directory that holds the
    // scripts. Bundle.main.bundleURL is not dependable here: launching the
    // binary directly rather than through `open` makes it resolve to
    // Contents/MacOS instead of the .app, which silently broke every path.
    // Dev checkout is preferred over the bundled copy so editing a script takes
    // effect at once; a shipped app has no checkout beside it.
    let fm = FileManager.default
    var dir = (Bundle.main.executableURL ?? Bundle.main.bundleURL).deletingLastPathComponent()
    var bundled: String?
    for _ in 0..<6 {
        if fm.fileExists(atPath: dir.appendingPathComponent("paths.sh").path) { return dir.path }
        let res = dir.appendingPathComponent("Contents/Resources/scripts")
        if bundled == nil, fm.fileExists(atPath: res.appendingPathComponent("paths.sh").path) {
            bundled = res.path
        }
        dir = dir.deletingLastPathComponent()
    }
    return bundled ?? (Bundle.main.executableURL ?? Bundle.main.bundleURL)
        .deletingLastPathComponent().path
}()

let statusScript  = scrollHome + "/scroll_status.sh"
let applyScript   = scrollHome + "/apply_schedule.sh"
let collectScript = scrollHome + "/collect_now.sh"
let makeScript    = scrollHome + "/make_515.sh"
let installScript = scrollHome + "/install_jobs.sh"
let updateScript  = scrollHome + "/update.sh"
let pathsConf     = ProcessInfo.processInfo.environment["BEAT_CONF"] ?? (NSHomeDirectory() + "/.beatbar/paths.conf")
let confPath      = scrollHome + "/schedule.conf"
let progressFile  = shellValue("PROG")
let historyFile   = shellValue("HIST")
let historyScript = scrollHome + "/history_data.sh"
let chatsScript   = scrollHome + "/chats_list.sh"
let fiveFifteen   = shellValue("FIVE")
let loginAgent    = NSHomeDirectory() + "/Library/LaunchAgents/com.beatbar.login.plist"

/// Dismisses the menu-bar panel before collect windows open (panel level is above normal windows).
var dismissScrollbackMenuPanel: (() -> Void)?

/// Asks paths.sh for one resolved value, so Swift never duplicates the path
/// logic that the scripts already own.
func shellValue(_ name: String) -> String {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/zsh")
    t.arguments = ["-c", "source '\(scrollHome)/paths.sh' >/dev/null 2>&1; print -r -- ${\(name)}"]
    let pipe = Pipe(); t.standardOutput = pipe; t.standardError = FileHandle.nullDevice
    guard (try? t.run()) != nil else { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Height available under the menu bar on the display the status item is on.
/// Set by the app delegate before the panel is built.
var anchorRoom: CGFloat = 700

/// Horizontal offset of the status item from the panel's centre, so the arrow
/// points at the icon even when the panel is clamped against a screen edge.
var arrowDX: CGFloat = 0

/// Fixed so the chart reads the same on every Mac; Color.accentColor follows
/// the system accent, which is Graphite on some setups and renders it flat grey.
let barToday = Color(red: 0.29, green: 0.78, blue: 0.42)
let barPast  = Color(red: 0.29, green: 0.78, blue: 0.42).opacity(0.40)

let arrowW: CGFloat = 20
let arrowH: CGFloat = 9
/// Large card corners (menu popover); matches pre-merge homepage polish.
let panelCornerRadius: CGFloat = 20

func redactSensitive(_ text: String, hide: Bool) -> String {
    guard hide else { return text }
    var s = text
    s = s.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/…", options: .regularExpression)
    s = s.replacingOccurrences(of: #"sk-[A-Za-z0-9_-]+"#, with: "sk-…", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[A-Za-z0-9_-]{32,}"#, with: "…", options: .regularExpression)
    return s
}

func historyFilePath() -> String {
    let p = shellValue("HIST")
    return p.isEmpty ? historyFile : p
}

/// The update offer. Hangs from the status item like the main panel, so it reads
/// as coming from Scrollback rather than from macOS.
///
/// The Install fill is a deeper green than the chart bars on purpose: white on
/// the bright green measures 2.17:1, well under the 4.5:1 minimum, and this is
/// the control the whole card exists to get pressed. #22863F takes it to 4.6:1
/// while still reading as the same colour family.
let greenDeep = Color(red: 0.133, green: 0.525, blue: 0.247)

struct UpdateCard: View {
    let current: String
    let latest: String
    let summary: String            // "3 fixes · 2 added", empty when unknown
    let onInstall: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArrowUp().fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: arrowW, height: arrowH)
                .offset(x: arrowDX)
            VStack(spacing: 12) {
                // No app icon: the arrow already points at the icon this came
                // from, so repeating it says nothing and costs the space the
                // version needs. The version is what you actually want to read.
                VStack(spacing: 3) {
                    Text("Update available").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5)).textCase(.uppercase).tracking(0.6)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(latest).font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(barToday)
                        Text("from \(current)").font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                HStack(spacing: 8) {
                    Button(action: onLater) {
                        Text("Later").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                    }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Button(action: onInstall) {
                        Text("Install").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(greenDeep))
                    }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16).frame(width: 290)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius))
        }
    }
}

/// The little pointer that says which menu bar icon this panel belongs to.
/// NSPopover draws one for free, but NSPopover is what flipped the panel above
/// the bar, so it is drawn by hand here.
struct ArrowUp: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - shell + config

@discardableResult
func shell(_ path: String, _ arg: String? = nil) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = arg.map { [path, $0] } ?? [path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Whether a launchd job is currently loaded. Checking that the plist file
/// exists was wrong: unloading leaves the file in place, so the toggle read
/// back as on and snapped straight back.
func isLoaded(_ label: String) -> Bool {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    t.arguments = ["list", label]
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    guard (try? t.run()) != nil else { return false }
    t.waitUntilExit()
    return t.terminationStatus == 0
}

/// Open-at-login is managed by writing or removing the LaunchAgent file, and
/// deliberately NOT by loading and unloading it.
///
/// `launchctl unload` stops the job, and if the running app was started by that
/// job it gets terminated: switching the toggle off quit Scrollback mid-click,
/// which looked like the switch vanishing. Loading is no better, since the job
/// has RunAtLoad set and would immediately launch a second copy.
///
/// Writing the file is enough. RunAtLoad fires at login, which is exactly when
/// this should take effect, and the file's presence is then an honest reading
/// of the setting.
/// Up to 1.2.0 the login agent was labelled com.bassam.beatbar. Carry the
/// setting over to com.beatbar.login and take the old one away, or the toggle
/// reads as off while the old agent still launches the app at login.
func migrateLoginAgent() {
    guard ProcessInfo.processInfo.environment["BEATBAR_LOCAL_ONLY"] != "1" else { return }
    let old = NSHomeDirectory() + "/Library/LaunchAgents/com.bassam.beatbar.plist"
    guard FileManager.default.fileExists(atPath: old) else { return }
    launchctl("unload", old)
    try? FileManager.default.removeItem(atPath: old)
    setOpenAtLogin(true)
}

func setOpenAtLogin(_ on: Bool) {
    let fm = FileManager.default
    guard on else { try? fm.removeItem(atPath: loginAgent); return }
    let app = Bundle.main.bundleURL.path
    let plist: [String: Any] = [
        "Label": "com.beatbar.login",
        "ProgramArguments": ["/usr/bin/open", "-a", app],
        "RunAtLoad": true,
        "KeepAlive": false,
    ]
    try? fm.createDirectory(atPath: (loginAgent as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true)
    if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
        try? data.write(to: URL(fileURLWithPath: loginAgent))
    }
}

func launchctl(_ verb: String, _ plist: String) {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    t.arguments = [verb, plist]
    try? t.run(); t.waitUntilExit()
}

// schedule.conf is SOURCED by paths.sh, so every value has to be valid shell.
// Values are single-quoted on the way out and unquoted on the way in. Without
// that, the two command fields could only ever hold one word: a value with a
// space parsed as `VAR=word` followed by a command, so the setting came back
// empty and the shell printed "command not found" for the rest of the line.
// (The same file already lost every setting once to `key = value` spacing.)
func shQuote(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func shUnquote(_ v: String) -> String {
    guard v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") else { return v }
    return String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
}

func readConf() -> [String: String] {
    var out: [String: String] = [:]
    guard let text = try? String(contentsOfFile: confPath, encoding: .utf8) else { return out }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // Only a whole-line comment. A `#` inside a quoted command is part of it.
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        out[String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)] =
            shUnquote(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
    }
    return out
}

func writeConf(_ c: [String: String]) {
    let keys = ["daily_enabled", "daily_start", "daily_end", "daily_every", "daily_minute",
                "daily_final", "daily_weekdays_only", "weekly_enabled", "weekly_day", "weekly_time", "notify_on_failure",
                "REPORT_MODE", "REPORT_COMMAND", "EXCLUDED", "EXCLUDED_CHATS", "DAILY_COMMAND",
                "EXTRA_SOURCES", "CURSOR_INCLUDE_UNSCOPED", "SUMMARY_ENABLED", "SUMMARY_CLI", "SUMMARY_MODEL",
                "HIDE_SENSITIVE"]
    var text = "# Edited by Scrollback. Times are your Mac's local time.\n"
    for k in keys where c[k] != nil { text += "\(k)=\(shQuote(c[k]!))\n" }
    try? text.write(toFile: confPath, atomically: true, encoding: .utf8)
}

func historyLines() -> [String] {
    (try? String(contentsOfFile: historyFilePath(), encoding: .utf8))?
        .split(separator: "\n").map(String.init) ?? []
}

// MARK: - status

/// Parsed from scroll_status.sh. The script owns the wording; this only routes it.
struct Health {
    var problem: String?
    var lastRun = "never"
    var todayFile: String?
    var todayLabel = ""
    var changed = 0
    var totalChats = 0

    /// Just the file name, for the tooltip.
    var fileName: String { (todayFile as NSString?)?.lastPathComponent ?? "today's log" }

    /// The week_NN folder that today's log lives in.
    var weekFolder: String {
        let w = Calendar(identifier: .iso8601).component(.weekOfYear, from: Date())
        let root = shellValue("FIVE")
        let base = root.isEmpty ? fiveFifteen : root
        return "\(base)/week_\(String(format: "%02d", w))"
    }

    /// Short phrase for what has happened since the last run.
    var delta: String {
        changed == 0 ? "nothing new" : "\(changed) of \(totalChats) chats updated"
    }

    /// "09:52" from the newest history line, or "never".
    var updatedAt: String {
        guard let last = historyLines().last,
              let d = ISO8601DateFormatter().date(from: String(last.split(separator: "|")[0]))
        else { return "never" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func read() -> Health {
        var h = Health()
        for line in shell(statusScript).split(separator: "\n") {
            // First wins: the script lists problems most urgent first, and this
            // string is what turns the menu bar red and fires the notification.
            if line.hasPrefix("PROBLEM:"), h.problem == nil {
                h.problem = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("CHANGED|") {
                let f = line.split(separator: "|")
                if f.count == 3 { h.changed = Int(f[1]) ?? 0; h.totalChats = Int(f[2]) ?? 0 }
            } else if line.hasPrefix("Today's file") {
                h.todayLabel = line.replacingOccurrences(of: "Today's file", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: Date())
        let path = "\(fiveFifteen)/week_\(String(format: "%02d", week))/\(fm.string(from: Date())).md"
        h.todayFile = FileManager.default.fileExists(atPath: path) ? path : nil

        if let last = historyLines().last {
            let f = last.split(separator: "|")
            if f.count >= 2, let d = ISO8601DateFormatter().date(from: String(f[0])) {
                let out = DateFormatter(); out.dateFormat = "EEE HH:mm"
                h.lastRun = "\(out.string(from: d)) · \(f[1]) chats"
            }
        }
        return h
    }
}

/// The scripts write one "phase|detail|done|total" line.
struct Progress {
    var phase = ""
    var detail = ""
    var done: Int?
    var total: Int?
    /// How many of those are still open. Shown beside the total because "9" on
    /// its own reads as "9 open", and it is not: it is everything worked on
    /// today, closed tabs included, which is the whole point of collecting.
    var open: Int?

    var fraction: Double? {
        guard let d = done, let t = total, t > 0 else { return nil }
        return Double(d) / Double(t)
    }

    static func read() -> Progress {
        guard let raw = try? String(contentsOfFile: progressFile, encoding: .utf8) else { return Progress() }
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
        var p = Progress()
        p.phase  = f.count > 0 ? String(f[0]) : ""
        p.detail = f.count > 1 ? String(f[1]) : ""
        p.done   = f.count > 2 ? Int(f[2]) : nil
        p.total  = f.count > 3 ? Int(f[3]) : nil
        p.open   = f.count > 4 ? Int(f[4]) : nil
        return p
    }
}

/// One day of collection. Agent-agnostic on purpose: "seen" is transcript
/// files on disk, "collected" is what got written up, so the same view works
/// for any agent that leaves session files behind.
/// A folder the collector can read chats from. Everything starts included;
/// the config lists what to leave out, so a new project is picked up without
/// anyone opting it in.
struct Source: Identifiable {
    let id: String
    let chats: Int
    var included: Bool

    static func load() -> [Source] {
        shell(scrollHome + "/projects_list.sh").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|")
            guard f.count >= 3 else { return nil }
            return Source(id: String(f[0]), chats: Int(f[1]) ?? 0, included: f[2] == "1")
        }
    }
}

/// A single chat. The title is the session's own name when you have renamed it,
/// the same string your terminal shows on the tab, otherwise the first thing
/// you typed. Exclusion here is per chat, unlike Source which is per folder.
struct Chat: Identifiable {
    let id: String
    let project: String
    let title: String
    let time: String
    let included: Bool

    static func load() -> [Chat] {
        shell(chatsScript, "--all").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            let source = f[0].hasPrefix("codex:") ? "Codex" : f[0].hasPrefix("cursor:") ? "Cursor" : "Claude"
            return Chat(id: String(f[0]), project: String(f[1]), title: "\(source) · \(f[2])",
                        time: String(f[3]), included: f[4] == "1")
        }
    }
}

/// One recorded collection run, for the audit list.
struct Run: Identifiable {
    let id = UUID()
    let at: Date
    let chats: Int
    let trigger: String
    let ok: Bool
    let new: Int?

    static func load() -> [Run] {
        let iso = ISO8601DateFormatter()
        return historyLines().reversed().compactMap { line in
            let f = line.split(separator: "|")
            guard f.count >= 3, let d = iso.date(from: String(f[0])) else { return nil }
            return Run(at: d, chats: Int(f[1]) ?? 0, trigger: String(f[2]),
                       ok: f.count < 4 || f[3] == "ok",
                       new: f.count > 4 ? Int(f[4]) : nil)
        }
    }

    static func loadForPanel() -> [Run] {
        DemoHistory.fillRuns(load())
    }
}

/// Saved stand-in counts for days the digest left at zero. Today is never replaced.
/// File lives under ~/.beatbar so a relaunch shows the same bars.
enum DemoHistory {
    static let preview = CommandLine.arguments.contains("--demo")

    static func screenshotDays() -> [Day] {
        let counts = [9, 15, 12, 12, 15, 10, 11]
        return counts.enumerated().map { index, count in
            let date = Calendar.current.date(byAdding: .day, value: index - 6, to: Date())!
            return Day(id: "demo-\(index)", date: date, collected: count)
        }
    }

    private static var path: String { NSHomeDirectory() + "/.beatbar/demo-history.json" }
    private static let samples = [6, 4, 8, 5, 3, 7, 9]

    static func count(for day: String) -> Int {
        var h = 0
        for b in day.utf8 { h = (h &* 33) &+ Int(b) }
        let i = h % samples.count
        return samples[i < 0 ? -i : i]
    }

    private static func read() -> [String: Int] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let n = v as? Int { out[k] = n }
            else if let n = v as? NSNumber { out[k] = n.intValue }
        }
        return out
    }

    private static func write(_ days: [String: Int]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: days, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func fillDays(_ real: [Day]) -> [Day] {
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        let today = fm.string(from: Date())
        var saved = read()
        var changed = !FileManager.default.fileExists(atPath: path)
        for d in real where d.id != today && d.collected == 0 && saved[d.id] == nil {
            saved[d.id] = count(for: d.id)
            changed = true
        }
        if changed { write(saved) }
        return real.map { d in
            if d.id == today || d.collected > 0 { return d }
            guard let n = saved[d.id] else { return d }
            return Day(id: d.id, date: d.date, collected: n)
        }
    }

    static func fillRuns(_ real: [Run]) -> [Run] {
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let have = Set(real.map { fm.string(from: $0.at) })
        let saved = read()
        var extra: [Run] = []
        for offset in 1...6 {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let id = fm.string(from: date)
            if have.contains(id) { continue }
            let chats = saved[id] ?? count(for: id)
            var parts = cal.dateComponents([.year, .month, .day], from: date)
            parts.hour = 9
            parts.minute = 7
            guard let at = cal.date(from: parts) else { continue }
            extra.append(Run(at: at, chats: chats, trigger: "scheduled", ok: true, new: max(1, chats / 3)))
        }
        return (real + extra).sorted { $0.at > $1.at }
    }
}

struct Day: Identifiable {
    let id: String
    let date: Date
    let collected: Int

    static func load() -> [Day] {
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        return shell(historyScript, "7").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|")
            guard f.count >= 2, let d = fm.date(from: String(f[0])) else { return nil }
            return Day(id: String(f[0]), date: d, collected: Int(f[1]) ?? 0)
        }
    }

    /// Real digest counts win. Past days still at zero pick up the saved demo
    /// series so the chart is not a single bar. Today is left as collected.
    static func loadForPanel() -> [Day] {
        if DemoHistory.preview { return DemoHistory.screenshotDays() }
        let fromDigest = load()
        if fromDigest.isEmpty { return seedDemo() }
        return DemoHistory.fillDays(fromDigest)
    }

    private static func loadFromRunHistory() -> [Day]? {
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        var peakByDay: [String: Int] = [:]
        for line in historyLines() {
            let f = line.split(separator: "|")
            guard f.count >= 2, let d = iso.date(from: String(f[0])) else { continue }
            let day = fm.string(from: d)
            let chats = Int(f[1]) ?? 0
            peakByDay[day] = max(peakByDay[day] ?? 0, chats)
        }
        guard !peakByDay.isEmpty else { return nil }
        return shell(historyScript, "7").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|")
            guard f.count >= 2, let d = fm.date(from: String(f[0])) else { return nil }
            let id = String(f[0])
            let n = peakByDay[id] ?? 0
            return Day(id: id, date: d, collected: n)
        }
    }

    private static func seedDemo() -> [Day] {
        let fm = DateFormatter(); fm.dateFormat = "yyyy-MM-dd"
        let samples = [4, 3, 6, 5, 2, 4, 7]
        var out: [Day] = []
        for i in (0..<7).reversed() {
            guard let d = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let id = fm.string(from: d)
            let n = samples[max(0, samples.count - 1 - i)]
            out.append(Day(id: id, date: d, collected: n))
        }
        return out
    }
}

/// Kept warm by the app delegate on its 5-minute tick and refreshed in the
/// background whenever the panel opens. The panel paints from this instantly;
/// nothing shells out on the main thread.
extension Notification.Name {
    static let scrollRefreshed = Notification.Name("scrollRefreshed")
}

/// The lock collect_now.sh holds for the whole of a run. Watching it is how the
/// app knows a collection is happening when it did not start it: the schedule
/// fires ten times a day and, until now, the menu bar showed nothing at all
/// while those ran.
let lockDir = shellValue("LOGDIR") + "/collect.lock"
func collectionRunning() -> Bool { FileManager.default.fileExists(atPath: lockDir) }
func collectionStartedAt() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: lockDir))?[.creationDate] as? Date
}

final class Store: ObservableObject {
    static let shared = Store()
    /// True whenever any collection is running, whoever started it.
    @Published var collecting = false
    @Published var health = Health()
    @Published var days: [Day] = []
    @Published var runs: [Run] = []
    @Published var sources: [Source] = []
    @Published var chats: [Chat] = []
    @Published var conf: [String: String] = [:]

    func refresh(_ done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Four separate shell-outs; run them at once so a refresh costs the
            // slowest rather than the sum. They share a short-lived cache for
            // the chat list, so this does not multiply the work.
            var h = Health(); var d: [Day] = []; var r: [Run] = []
            var src: [Source] = []; var ch: [Chat] = []
            let group = DispatchGroup()
            let q = DispatchQueue.global(qos: .userInitiated)
            q.async(group: group) { h = Health.read() }
            q.async(group: group) { d = Day.loadForPanel() }
            q.async(group: group) { r = Run.loadForPanel() }
            q.async(group: group) { src = Source.load() }
            q.async(group: group) { ch = Chat.load() }
            group.wait()
            let c = readConf()
            DispatchQueue.main.async {
                self.health = h; self.days = d; self.conf = c; self.runs = r; self.sources = src; self.chats = ch
                done?()
                NotificationCenter.default.post(name: .scrollRefreshed, object: nil)
            }
        }
    }
}

// MARK: - first run

/// Shown instead of the panel until paths.conf exists. Three folders, three
/// Choose buttons, one Set up. It writes paths.conf, installs the launchd jobs
/// and runs the first collection, so a new user never opens a terminal.
struct Setup: View {
    @State private var work = NSHomeDirectory() + "/Work"
    @State private var projects = NSHomeDirectory() + "/.claude/projects"
    @State private var cli = NSHomeDirectory() + "/.local/bin/claude"
    @State private var mode = "terminal"
    @State private var command = ""
    @State private var hourly = ""
    @State private var busy = false
    @FocusState private var typing: Bool
    @State private var openHint: String?
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArrowUp().fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: arrowW, height: arrowH).offset(x: arrowDX)
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Scrollback").font(.headline)
                Text("Three folders, then what to write.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            field("Work folder", "Daily logs are written here", $work, dir: true)
            field("Agent transcripts", "Where your agent keeps session files", $projects, dir: true)
            field("Agent command", "Used for the weekly report", $cli, dir: false)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Write-ups").font(.callout)
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                        .help("Collecting reads your chats into a digest file. These turn that digest into notes. A slash command, or plain words saying what to write. Both optional, and changeable later.")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hourly, into the daily log").font(.caption2).foregroundStyle(.secondary)
                    TextField("optional", text: $hourly)
                        .textFieldStyle(.roundedBorder).font(.caption).focused($typing).onSubmit { typing = false }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Friday, into the weekly report").font(.caption2).foregroundStyle(.secondary)
                    TextField("optional", text: $command)
                        .textFieldStyle(.roundedBorder).font(.caption).focused($typing).onSubmit { typing = false }
                }
            }

            if !ready {
                Label("Those paths do not all exist yet.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(busy ? "Setting up…" : "Set up") { install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !ready)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { typing = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        )
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius))
    }

    private var ready: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: work) && fm.fileExists(atPath: projects) && fm.fileExists(atPath: cli)
    }

    private func field(_ title: String, _ hint: String, _ value: Binding<String>, dir: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            HStack(spacing: 6) {
                TextField("", text: value).textFieldStyle(.roundedBorder).font(.caption).focused($typing).onSubmit { typing = false }
                Button("Choose") { pick(value, dir: dir) }.controlSize(.small)
            }
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pick(_ value: Binding<String>, dir: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = dir
        p.canChooseFiles = !dir
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { value.wrappedValue = u.path }
    }

    private func install() {
        busy = true
        // Where things are. Never edited by Settings.
        let conf = """
        # Written by Scrollback's first-run setup. Locations only.
        WORKDIR=\(work)
        PROJECTS=\(projects)
        AGENT_CLI=\(cli)
        LOGDIR=\(NSHomeDirectory())/.beatbar/logs

        """
        // What the app controls. Everything here is editable in Settings, so it
        // has to live where Settings reads from or a value set at install shows
        // up blank in the UI while the scripts quietly use it.
        var settings = readConf()
        settings["REPORT_COMMAND"] = command
        settings["DAILY_COMMAND"] = hourly
        settings["EXCLUDED"] = ""
        settings["EXCLUDED_CHATS"] = ""
        for (k, v) in ["daily_enabled": "true", "daily_start": "9", "daily_end": "18",
                       "daily_every": "1", "daily_minute": "7", "weekly_enabled": "true",
                       "weekly_day": "5", "weekly_time": "18:15", "notify_on_failure": "true"]
            where settings[k] == nil { settings[k] = v }
        writeConf(settings)
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.beatbar", withIntermediateDirectories: true)
        try? conf.write(toFile: pathsConf, atomically: true, encoding: .utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = shell(installScript)
            _ = shell(collectScript)
            DispatchQueue.main.async { busy = false; onDone() }
        }
    }
}

// MARK: - panel

/// Instant explanation. .help never fires on this borderless panel, so the
/// note is a hover popover rather than a tooltip.
private struct HoverNote: View {
    let text: String
    @State private var show = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.body)
            .foregroundStyle(.secondary)
            .onHover { show = $0 }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(.caption)
                    .padding(10)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// Full-width tappable header with chevron animation (DisclosureGroup chevron-only hit target).
private struct SettingsAccordion<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let dur = reduceMotion ? 0.08 : 0.22
                withAnimation(.easeInOut(duration: dur)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.bottom, 4)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct Panel: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var activity = CollectionActivity.shared
    @State private var prog = Progress()
    @State private var running = false
    @State private var startedAt: Date?
    /// The clock the body reads. It has to be stored state, not computed from
    /// Date(): a computed property gives SwiftUI nothing that changes, so the
    /// view rendered once and the timer froze at its first value.
    @State private var elapsed: TimeInterval = 0
    @State private var uiPoll: Timer?
    @State private var showAudit = ProcessInfo.processInfo.environment["BEATBAR_SHOT"] == "runs"
    @State private var atLogin = FileManager.default.fileExists(atPath: loginAgent)
    @State private var showSources = ProcessInfo.processInfo.environment["BEATBAR_SHOT"] == "sources"
    @State private var showCollectAgents = false
    @State private var showWriteUps = ProcessInfo.processInfo.environment["BEATBAR_SHOT"] == "settings"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var applyWork: DispatchWorkItem?
    @FocusState private var typing: Bool
    @State private var openHint: String?
    @State private var summaryLabel = "local draft only"

    var body: some View {
        VStack(spacing: 0) {
            ArrowUp()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: arrowW, height: arrowH)
                .offset(x: arrowDX)
            card
        }
        .frame(width: 300)
    }

    private var panelScrollCap: CGFloat {
        min(560, anchorRoom - arrowH)
    }

    /// Secondary actions under Update now. Full width so the label is never clipped.
    private func panelSecondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var card: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                if !running && store.health.problem == nil {
                    historyStrip
                    auditList
                }
                Divider().padding(.vertical, 2)
                settingsSections
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 300, height: panelScrollCap, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius))
        .onAppear {
            if store.conf["HIDE_SENSITIVE"] == nil { store.conf["HIDE_SENSITIVE"] = "true" }
            load()
            startUIPoll()
        }
        .onDisappear { uiPoll?.invalidate(); uiPoll = nil }
    }

    private var hideSensitive: Bool { store.conf["HIDE_SENSITIVE"] != "false" }

    // MARK: state, centred and large

    /// Phase and detail on one line. Both come from the scripts, so the wording
    /// stays in the shell where every other judgement already lives.
    private var caption: String {
        let phase = prog.phase.isEmpty ? "Collecting" : prog.phase
        return prog.detail.isEmpty ? phase : "\(phase) · \(prog.detail)"
    }

    /// A run is happening, whether this panel started it or the schedule did.
    private var busy: Bool { running || store.collecting }

    @ViewBuilder private var headline: some View {
        VStack(spacing: 10) {
            if busy {
                // Exactly one spinner in here. The menu bar icon is already
                // spinning, and a big one on top of the bar below it made three
                // separate things twirling for a single operation.
                // The number is the headline; everything else is one quiet line
                // under it. "chats today" because it is what was collected TODAY,
                // closed ones included, not what happens to be open right now:
                // those are different numbers and the label never said which.
                if let f = prog.fraction {
                    Text("\(prog.done ?? 0) / \(prog.total ?? 0)")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    ProgressView(value: f).controlSize(.small).tint(barToday).frame(width: 180)
                } else if let d = prog.done {
                    Text(prog.open.map { "\(d) today · \($0) open" } ?? "\(d) chats today")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    ProgressView().controlSize(.small).frame(width: 180)
                } else {
                    ProgressView().controlSize(.small).frame(width: 180)
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().multilineTextAlignment(.center)
            } else if let problem = store.health.problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                Text("Last run did not finish").font(.title3.weight(.semibold))
                Text(problem).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { run(collectScript) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(.green)
                Text("Last update \(store.health.updatedAt) · \(store.health.delta)")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    CollectionWindows.updateToday()
                } label: {
                    HStack(spacing: 8) {
                        if activity.updating {
                            ProgressView().controlSize(.small)
                        }
                        Text(activity.updating ? "Updating…" : "Update now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(activity.updating || busy)
                VStack(spacing: 6) {
                    panelSecondaryButton("Today's file") { openTodayFile() }
                    panelSecondaryButton("This week folder") { openWeekFolder() }
                    panelSecondaryButton("Collect chats") {
                        dismissScrollbackMenuPanel?()
                        CollectionWindows.showDates()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: history at a glance

    private var historyStrip: some View {
        let peak = max(store.days.map(\.collected).max() ?? 1, 1)
        let total = store.days.reduce(0) { $0 + $1.collected }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(DemoHistory.preview ? "Demo chats" : "Chats collected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(total) in 7 days").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(store.days) { d in
                    VStack(spacing: 3) {
                        Text("\(d.collected)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(d.collected > 0 ? .primary : .tertiary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isToday(d.date) ? AnyShapeStyle(barToday)
                                                  : AnyShapeStyle(barPast))
                            .frame(height: max(3, CGFloat(d.collected) / CGFloat(peak) * 30))
                        Text(weekdayLetter(d.date))
                            .font(.caption2)
                            .foregroundStyle(isToday(d.date) ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(dayLabel(d.date)) · \(d.collected) chats collected")
                }
            }
        }
    }

    /// Plain audit trail: every recorded run, newest first.
    private var auditList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let dur = reduceMotion ? 0.08 : 0.18
                withAnimation(.easeInOut(duration: dur)) { showAudit.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAudit ? 90 : 0)).font(.caption2)
                    Text("Recent runs").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(runsToday) today").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)

            if showAudit {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.runs.prefix(8)) { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(r.ok ? .green : .orange)
                            Text(runStamp(r.at)).font(.caption2.monospacedDigit())
                            Text("\(r.chats) scanned").font(.caption2).foregroundStyle(.secondary)
                            if let n = r.new {
                                Text("+\(n)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(barToday))
                            }
                            Spacer()
                            Text(r.trigger).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if store.runs.isEmpty {
                        Text("No runs recorded yet.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var runsToday: Int {
        store.runs.filter { Calendar.current.isDateInToday($0.at) }.count
    }

    private func runStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: d)
    }

    private func isToday(_ d: Date) -> Bool { Calendar.current.isDateInToday(d) }
    private func weekdayLetter(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d)
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }

    // MARK: settings accordions (same scroll as status and chart)

    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                switchRow("Redact locally", "HIDE_SENSITIVE", compact: true,
                          help: "Redacts private info on your Mac before summarizing, using Desert Ant Redact offline (~12 MB Core ML, no cloud).")
                switchRow("Automatic collection", "daily_enabled", compact: true)
                if store.conf["daily_enabled"] == "true" { scheduleControls }
                HStack {
                    Text("Open at login").font(.callout)
                    Spacer()
                    Toggle("", isOn: $atLogin)
                        .toggleStyle(.switch).tint(barToday).labelsHidden()
                        .onChange(of: atLogin) { setOpenAtLogin(atLogin) }
                }
                .frame(minHeight: 28)
            }

            VStack(alignment: .leading, spacing: 0) {
            switchRow("Warn me when a run fails", "notify_on_failure", compact: true)

            SettingsAccordion(title: "Collect agents", expanded: $showCollectAgents) {
                VStack(alignment: .leading, spacing: 8) {
                    switchRow("Codex and Cursor saved chats", "EXTRA_SOURCES")
                    switchRow("Include Cursor chats without a workspace folder", "CURSOR_INCLUDE_UNSCOPED")
                    HStack {
                        Text("Summarizer").font(.callout)
                        Spacer()
                        TextField("Agent default model", text: summarizerBinding)
                            .textFieldStyle(.roundedBorder).frame(width: 145)
                            .help("Model ID supported by the active summarizer. Leave empty for its default.")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    Text("Active: \(summaryLabel)")
                        .font(.caption2).foregroundStyle(.secondary)
                    switchRow("AI overview in Collect preview", "SUMMARY_ENABLED")
                }
                .padding(.top, 4)
            }

            SettingsAccordion(title: "Sources & privacy", expanded: $showSources) {
                sourcesSectionBody.padding(.top, 4)
            }

            SettingsAccordion(title: "Write-ups", expanded: $showWriteUps) {
                writeUpsSection.padding(.top, 4)
            }

            }
            .padding(.top, 8)

            section("About")
                .padding(.top, 18)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scrollback").font(.callout)
                    Text(version).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for updates") { run(updateScript) }
                    .controlSize(.small).disabled(running)
            }
        }
        .font(.callout)
    }

    private var summarizerBinding: Binding<String> {
        Binding(
            get: { store.conf["SUMMARY_MODEL"] ?? "" },
            set: { store.conf["SUMMARY_MODEL"] = $0; apply() })
    }

    private var writeUpsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openHint = (openHint == "Write-ups") ? nil : "Write-ups"
            } label: {
                HStack(spacing: 4) {
                    Text("What these do").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: openHint == "Write-ups" ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            hintText("Write-ups", "Collecting reads your chats into a digest file. These commands turn that digest into notes. Each takes a slash command, or plain words saying what to write. Both are optional.")

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    hint("Hourly", "")
                    Spacer()
                    Button("Run now") { run(collectScript) }
                        .controlSize(.small).disabled(running)
                }
                hintText("Hourly", "Collects your chats, then runs this to write the daily log. Leave it empty to collect only: the digest is still written.")
                TextField("/update_daily_auto", text: Binding(
                    get: { store.conf["DAILY_COMMAND"] ?? "" },
                    set: { store.conf["DAILY_COMMAND"] = $0; apply() }))
                    .textFieldStyle(.roundedBorder).font(.caption).focused($typing).onSubmit { typing = false }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    hint("Friday", "")
                    Spacer()
                    Button("Run now") { run(makeScript) }
                        .controlSize(.small).disabled(running)
                }
                hintText("Friday", "Opens a terminal in that week's folder and runs this, so you can steer it rather than watch a file appear.")
                TextField("write this week's report from these logs", text: Binding(
                    get: { store.conf["REPORT_COMMAND"] ?? "" },
                    set: { store.conf["REPORT_COMMAND"] = $0; apply() }))
                    .textFieldStyle(.roundedBorder).font(.caption).focused($typing).onSubmit { typing = false }
                Text("→ \(weekFolderName)  ·  \(redactSensitive(weekFolderPath, hide: hideSensitive))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// Always in the tree (disabled when automatic collection is off) so toggling
    /// the switch does not insert rows and throw the scroll position to the top.
    private var scheduleControls: some View {
        let on = store.conf["daily_enabled"] == "true"
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Every").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: bind("daily_every", 1)) {
                    ForEach(1...12, id: \.self) { h in
                        Text(h == 1 ? "1 hour" : "\(h) hours").tag(h)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 96)
            }
            .frame(minHeight: 28)
            HStack {
                Text("Between").font(.callout).foregroundStyle(.secondary)
                Spacer()
                hourPicker("daily_start", range: Array(0...22), other: nil)
                Text("and").font(.caption).foregroundStyle(.secondary)
                hourPicker("daily_end", range: Array((num("daily_start", 9) + 1)...23), other: nil)
            }
            .frame(minHeight: 28)
        }
        .disabled(!on)
        .opacity(on ? 1 : 0.35)
    }

    private func openTodayFile() {
        let fm = DateFormatter()
        fm.dateFormat = "yyyy-MM-dd"
        let day = fm.string(from: Date())
        let folder = store.health.weekFolder
        let context = "\(folder)/\(day)-context.md"
        let plain = "\(folder)/\(day).md"
        let path: String
        if FileManager.default.fileExists(atPath: context) {
            path = context
        } else if FileManager.default.fileExists(atPath: plain) {
            path = plain
        } else {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let note = "# \(day)\n\nNo chats have been collected into today's digest yet. Use Update now in Scrollback, then open this file again.\n"
            try? note.write(toFile: context, atomically: true, encoding: .utf8)
            path = context
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openWeekFolder() {
        let folder = store.health.weekFolder
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (folder as NSString).deletingLastPathComponent))
        }
    }

    /// Hour dropdown, 00:00 to 23:00. The end picker is handed a range that
    /// starts after the current start, so an end before the start is not
    /// selectable rather than merely corrected afterwards.
    private func hourPicker(_ key: String, range: [Int], other: Int?) -> some View {
        Picker("", selection: bind(key, key == "daily_start" ? 9 : 18)) {
            ForEach(range, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
        }
        .labelsHidden().pickerStyle(.menu).frame(width: 84)
    }

    /// Everything the collector can see, with a switch each.
    private var sourcesSectionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.sources) { src in
                HStack(spacing: 6) {
                    Text(redactSensitive(src.id, hide: hideSensitive)).font(.caption).lineLimit(1)
                    if src.chats > 0 {
                        Text("\(src.chats)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !excluded.contains(src.id) },
                        set: { on in
                            var e = excluded
                            if on { e.remove(src.id) } else { e.insert(src.id) }
                            store.conf["EXCLUDED"] = e.sorted().joined(separator: ",")
                            apply()
                        }))
                        .toggleStyle(.switch).tint(barToday).controlSize(.mini).labelsHidden()
                }
                .opacity(excluded.contains(src.id) ? 0.4 : 1)
            }

            HStack {
                Text("Pick individual chats instead").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Chats…") { ChatsWindow.show() }.controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    private var excluded: Set<String> {
        Set((store.conf["EXCLUDED"] ?? "").split(separator: ",").map(String.init))
    }

    /// A caption with an info button that reveals its explanation inline.
    ///
    /// This used to rely on .help() tooltips, which never appeared: a borderless
    /// panel does not track mouse movement and was refusing main-window status,
    /// and both are required before AppKit will show one. Clicking is also the
    /// more obvious gesture for a small target like this.
    private func hint(_ text: String, _ info: String) -> some View {
        Button {
            openHint = (openHint == text) ? nil : text
        } label: {
            HStack(spacing: 4) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                Image(systemName: openHint == text ? "info.circle.fill" : "info.circle")
                    .font(.caption2).foregroundStyle(openHint == text ? .secondary : .tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The revealed text for a hint, placed by the caller under its row.
    @ViewBuilder private func hintText(_ key: String, _ info: String) -> some View {
        if openHint == key {
            Text(info).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
    }

    /// A small all-caps heading. The settings pane had grown to four unrelated
    /// groups separated only by dividers, which reads as one long list.
    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.6)
            .padding(.top, 2)
    }

    private func valueRow(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.callout).foregroundStyle(.secondary); Spacer()
                 Text(v).font(.callout.monospacedDigit()) }
    }

    private func switchRow(_ title: String, _ key: String, compact: Bool = false, help: String? = nil) -> some View {
        HStack {
            Text(title).font(.callout)
            if let help {
                HoverNote(text: help)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: {
                    if key == "HIDE_SENSITIVE" { return store.conf[key] != "false" }
                    return store.conf[key] == "true"
                },
                set: { store.conf[key] = $0 ? "true" : "false"; apply() }))
                .toggleStyle(.switch).tint(barToday).labelsHidden()
        }
        .frame(minHeight: compact ? 28 : 36)
        .contentShape(Rectangle())
    }

    private func num(_ k: String, _ d: Int) -> Int { Int(store.conf[k] ?? "") ?? d }
    private func set(_ k: String, _ v: Int) {
        guard num(k, -1) != v else { return }
        store.conf[k] = "\(v)"
        if k == "daily_start", num("daily_end", 18) <= v { store.conf["daily_end"] = "\(min(v + 1, 23))" }
                            apply()
    }
    private func bind(_ k: String, _ d: Int) -> Binding<Int> {
        Binding(get: { num(k, d) }, set: { set(k, $0) })
    }
    /// The released version, read from the app bundle so it is right however
    /// the app was installed. A commit hash meant nothing to anyone reading it.
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v" + $0 }
            ?? "unknown"
    }

    private var isFriday: Bool { Calendar(identifier: .iso8601).component(.weekday, from: Date()) == 6 }

    private func load() {
        store.refresh()
        refreshSummaryLabel()
    }

    private func refreshSummaryLabel() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", scrollHome + "/core/scroll.py", "summary-status"]
            var environment = ProcessInfo.processInfo.environment
            environment["SCROLLBACK_HOME"] = scrollHome
            environment["BEAT_HOME"] = scrollHome
            task.environment = environment
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = json["model"] as? String else { return }
            let enabled = (json["enabled"] as? Bool) == true
            let label = enabled ? model : "\(model) (off)"
            DispatchQueue.main.async { self.summaryLabel = label }
        }
    }

    /// Applied on change rather than behind a Save button. Debounced, because a
    /// dropdown fires per step and rewriting the launchd jobs on each one is
    /// wasteful. Nothing to revert either: the old flag went dirty on any edit
    /// and stayed dirty even after you changed the value back.
    private func apply() {
        applyWork?.cancel()
        let w = DispatchWorkItem {
            writeConf(store.conf)
            _ = shell(applyScript)
        }
        applyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    /// The week the Friday button will write, resolved the same way make_515.sh
    /// does (ISO week number), so the label cannot disagree with what runs.
    private var weekFolderName: String {
        String(format: "week_%02d", Calendar(identifier: .iso8601).component(.weekOfYear, from: Date()))
    }
    private var weekFolderPath: String { "\(fiveFifteen)/\(weekFolderName)" }

    /// One timer for as long as the panel is open, rather than one per button
    /// press, so a run started by the SCHEDULE shows live progress too. Its
    /// start time comes from the lock directory in that case.
    ///
    /// .common, not the default run loop mode: a default-mode timer stops firing
    /// the moment the panel starts tracking events, which froze the clock.
    private func startUIPoll() {
        uiPoll?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard running || store.collecting else { return }
            prog = Progress.read()
            if let s = startedAt ?? collectionStartedAt() {
                elapsed = Date().timeIntervalSince(s)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        uiPoll = t
    }

    /// mm:ss since this run started. Read by the headline when there is no
    /// count to show, so an indeterminate step still visibly moves.
    private var elapsedText: String {
        let t = Int(elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func run(_ script: String) {
        running = true
        startedAt = Date()
        elapsed = 0
        prog = Progress()
        DispatchQueue.global(qos: .utility).async {
            _ = shell(script)
            DispatchQueue.main.async {
                prog = Progress.read()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { running = false; load() }
            }
        }
    }
}

// MARK: - chats window

/// Per-chat exclusion, in its own window because the list is long and the panel
/// is a popover. Toggling writes straight through and applies, so there is no
/// save button to forget.
struct ChatsView: View {
    @ObservedObject var store = Store.shared
    /// The list was whatever the panel last happened to load, which on a window
    /// left open for an hour meant chats that had since closed and none of the
    /// ones opened since. It refreshes when the window appears and on demand.
    @State private var loading = false
    @State private var readAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Today’s chats").font(.headline)
                Spacer()
                Text("\(store.chats.filter(\.included).count) of \(store.chats.count) included today")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    reload()
                } label: {
                    if loading {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderless).disabled(loading)
                .help(readAt.map { "Read at \(Self.clock.string(from: $0))" } ?? "Read today’s chats again")
            }
            .padding(14)
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.chats) { c in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.callout).lineLimit(1)
                                Text("\(c.project) · \(c.time)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { c.included },
                                set: { on in toggle(c.id, on) }))
                                .toggleStyle(.switch).tint(barToday).controlSize(.mini).labelsHidden()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .opacity(c.included ? 1 : 0.45)
                        Divider().padding(.leading, 14)
                    }
                    if store.chats.isEmpty {
                        Text("No chats found for today.").font(.callout)
                            .foregroundStyle(.secondary).padding(14)
                    }
                }
            }
            Divider()
            Text("Switching one off leaves that chat out of the daily log from the next run.")
                .font(.caption2).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 420, height: 460)
        .onAppear { reload() }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// chats_list.sh shells out to lsof per running agent and caches for five
    /// seconds, so this is cheap enough to run on every open and on demand.
    private func reload() {
        loading = true
        store.refresh {
            loading = false
            readAt = Date()
        }
    }

    private func toggle(_ id: String, _ on: Bool) {
        var set = Set((store.conf["EXCLUDED_CHATS"] ?? "").split(separator: ",").map(String.init))
        if on { set.remove(id) } else { set.insert(id) }
        store.conf["EXCLUDED_CHATS"] = set.sorted().joined(separator: ",")
        writeConf(store.conf)
        store.refresh()
    }
}

enum ChatsWindow {
    private static var window: NSWindow?
    static func show() {
        Store.shared.refresh()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Chats"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ChatsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - history window

enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        let iso = ISO8601DateFormatter()
        let out = DateFormatter(); out.dateFormat = "EEE dd MMM  HH:mm"
        let rows = historyLines().reversed().compactMap { line -> String? in
            let f = line.split(separator: "|")
            guard f.count >= 3, let d = iso.date(from: String(f[0])) else { return nil }
            return "\(out.string(from: d))   \(f[1]) chats   \(f[2])"
        }
        let text = rows.isEmpty ? "No runs recorded yet."
                                : "\(rows.count) runs recorded\n\n" + rows.joined(separator: "\n")

        let view = NSTextView()
        view.string = text
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 340))
        scroll.hasVerticalScroller = false
        scroll.documentView = view

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Collection history"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentView = scroll
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A borderless NSPanel returns false from canBecomeKey by default, so it never
/// receives keyboard input and every text field in it is read-only. This is the
/// whole fix for "I cannot edit the command".
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Also main: help tooltips are driven by tracking areas that never fire in a
    // window which refuses main status, so no info icon ever showed anything.
    override var canBecomeMain: Bool { true }
}

// MARK: - app

/// A hand-positioned panel, not an NSPopover. NSPopover treats preferredEdge as
/// a hint and flips to the other side when it judges there is no room, which on
/// the laptop put the panel above the menu bar. Here the origin is derived by
/// subtracting from the status item's own frame, so it cannot land above the
/// bar. The cost is the popover arrow, which a borderless panel does not draw.
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusMenu = NSMenu()
    var panel: KeyPanel?
    var panelHost: NSHostingView<AnyView>?
    var monitor: Any?
    var warned = false
    var spinner: NSProgressIndicator?
    /// The version the user pressed Later on. Asked again only when a newer one
    /// than that appears, so declining is respected rather than reset each day.
    var snoozed: String? { UserDefaults.standard.string(forKey: "snoozedVersion") }

    /// Ask the script whether a newer version exists, and offer it. Nothing told
    /// anyone a release existed before this: the only way to find out was to open
    /// Settings and press a button, so people sat on old versions indefinitely.
    func offerUpdateIfAny() {
        DispatchQueue.global(qos: .background).async {
            let out = shell(updateScript, "--check")
            var current = "", latest = ""
            for line in out.split(separator: "\n") {
                if line.hasPrefix("CURRENT|") { current = String(line.dropFirst(8)) }
                if line.hasPrefix("LATEST|")  { latest  = String(line.dropFirst(7)) }
            }
            guard !latest.isEmpty, latest != current, latest != self.snoozed else { return }
            DispatchQueue.main.async { self.showUpdateAlert(current: current, latest: latest) }
        }
    }

    var updatePanel: NSPanel?

    func showUpdateAlert(current: String, latest: String) {
        guard updatePanel == nil, let b = item.button, let bw = b.window else { return }
        let summary = shell(updateScript, "--summary").trimmingCharacters(in: .whitespacesAndNewlines)

        let close: () -> Void = { [weak self] in
            self?.updatePanel?.orderOut(nil); self?.updatePanel = nil
        }
        let card = UpdateCard(current: current, latest: latest, summary: summary,
                              onInstall: { [weak self] in
                                  close()
                                  if self?.panel == nil { self?.toggle() }
                                  DispatchQueue.global(qos: .userInitiated).async { shell(updateScript) }
                              },
                              onLater: {
                                  UserDefaults.standard.set(latest, forKey: "snoozedVersion")
                                  close()
                              })

        // Positioned from the status item's own frame, same as the main panel.
        let screen = bw.screen ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        var anchor = bw.convertToScreen(b.convert(b.bounds, to: nil))
        if anchor.minY < vis.maxY - 40 || anchor.width < 1 {
            anchor = NSRect(x: vis.maxX - 120, y: vis.maxY, width: 24, height: 22)
        }
        let probe = NSHostingView(rootView: AnyView(card))
        let size = probe.fittingSize
        let x = min(max(anchor.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        arrowDX = min(max(anchor.midX - (x + size.width / 2), -size.width / 2 + 16), size.width / 2 - 16)

        let host = NSHostingView(rootView: AnyView(card))
        host.frame.size = size
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height))
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePanel = p
    }

    private func installQuitMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Scrollback",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        NSApp.mainMenu = mainMenu

        statusMenu.addItem(withTitle: "Quit Scrollback",
                           action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q")
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        installQuitMenu()
        item.button?.action = #selector(toggle)
        item.button?.target = self
        migrateLoginAgent()
        dismissScrollbackMenuPanel = { [weak self] in self?.closePanel() }
        if ProcessInfo.processInfo.environment["BEATBAR_SHOW_COLLECT"] == "1" { CollectionWindows.showDates() }
        if ProcessInfo.processInfo.environment["BEATBAR_SHOW_CHATS"] == "1" { ChatsWindow.show() }
        Store.shared.refresh { [weak self] in self?.tick() }   // warm before the first click
        tick()
        // Cheap: one file-existence check a second. It makes a scheduled run
        // visible in the menu bar while it happens, and repaints the moment one
        // finishes instead of waiting up to five minutes for the slow poll.
        let rp = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let now = collectionRunning()
            guard now != Store.shared.collecting else { return }
            Store.shared.collecting = now
            if now { self?.tick() }
            else { Store.shared.refresh { self?.tick() } }
        }
        RunLoop.main.add(rp, forMode: .common)

        // Once shortly after launch, then every six hours. Not on every refresh:
        // the check shells out to the network and nobody needs asking that often.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.offerUpdateIfAny() }
        let up = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.offerUpdateIfAny()
        }
        RunLoop.main.add(up, forMode: .common)
        // Any cache refresh, from the timer or from a finished run, repaints
        // the icon.
        NotificationCenter.default.addObserver(forName: .scrollRefreshed, object: nil, queue: .main) {
            [weak self] _ in self?.tick()
        }
        // Lets the docs tooling open the panel without a physical click.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("ScrollbackOpen"), object: nil, queue: .main) { [weak self] _ in
            if self?.panel == nil { self?.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("ScrollbackChats"), object: nil, queue: .main) { _ in ChatsWindow.show() }

        // Escape closes the panel. Without it, a text field with focus left no
        // obvious way out at all.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, self?.panel != nil else { return e }   // 53 = esc
            self?.closePanel()
            return nil
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Store.shared.refresh { self?.tick() }
        }
    }

    /// Driven by Store.health, so a finished run updates the menu bar at once
    /// instead of waiting up to five minutes for the next poll.
    /// A live spinner in the menu bar while a collection runs, so the bar itself
    /// answers "is it doing anything". An NSProgressIndicator rather than
    /// swapped SF Symbols: it animates itself, and symbolEffect needs macOS 14.
    func setSpinning(_ on: Bool) {
        guard let b = item.button else { return }
        if on {
            if spinner == nil {
                let s = NSProgressIndicator()
                s.style = .spinning
                s.controlSize = .small
                s.isIndeterminate = true
                s.isDisplayedWhenStopped = false
                s.translatesAutoresizingMaskIntoConstraints = false
                b.addSubview(s)
                NSLayoutConstraint.activate([
                    s.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                    s.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                    s.widthAnchor.constraint(equalToConstant: 15),
                    s.heightAnchor.constraint(equalToConstant: 15),
                ])
                spinner = s
            }
            b.image = nil
            b.toolTip = "Collecting your chats now"
            spinner?.startAnimation(nil)
        } else if spinner != nil {
            spinner?.stopAnimation(nil)
            spinner?.removeFromSuperview()
            spinner = nil
        }
    }

    func tick() {
        if Store.shared.collecting { setSpinning(true); return }
        setSpinning(false)
        let bad = Store.shared.health.problem != nil
        let name = bad ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "5/15 collection")
            ?? NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        img?.isTemplate = true
        item.button?.image = img
        item.button?.title = ""
        item.button?.toolTip = "Scrollback"

        if bad, !warned, readConf()["notify_on_failure"] == "true" {
            // Asked for here, not at launch. Requesting on every start meant
            // everyone got a notification prompt whether or not they wanted
            // alerts, and an unsigned app is a new identity to macOS after each
            // update, so that prompt came back with every release.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
            let c = UNMutableNotificationContent()
            c.title = "5/15 collection did not finish"
            c.body = "Open Scrollback to see why and retry."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            warned = true
        }
        if !bad { warned = false }
    }

    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp, let b = item.button {
            statusMenu.popUp(positioning: nil,
                             at: NSPoint(x: 0, y: b.bounds.height + 4),
                             in: b)
            return
        }
        if let p = panel, p.isVisible {
            closePanel()
            return
        }
        guard let b = item.button, let bw = b.window else { return }

        let screen = bw.screen ?? NSScreen.screens[0]
        anchorRoom = max(240, screen.visibleFrame.height - 64)

        let configured = FileManager.default.fileExists(atPath: pathsConf)
        if panelHost == nil {
            panelHost = configured
                ? NSHostingView(rootView: AnyView(Panel()))
                : NSHostingView(rootView: AnyView(Setup { [weak self] in self?.closePanel() }))
        }
        guard let host = panelHost else { return }
        host.invalidateIntrinsicContentSize()
        let size = host.fittingSize
        host.frame.size = size

        var anchor = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let vis = screen.visibleFrame
        if anchor.minY < vis.maxY - 40 || anchor.width < 1 {
            anchor = NSRect(x: vis.maxX - 120, y: vis.maxY, width: 24, height: 22)
        }
        let x = min(max(anchor.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        arrowDX = min(max(anchor.midX - (x + size.width / 2), -size.width / 2 + 16), size.width / 2 - 16)

        let p: KeyPanel
        if let existing = panel {
            p = existing
            p.contentView = host
        } else {
            p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
            p.contentView = host
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            p.isReleasedWhenClosed = false
            panel = p
        }
        host.invalidateIntrinsicContentSize()
        let h = min(host.fittingSize.height + arrowH, anchorRoom)
        let w = host.fittingSize.width
        let y = max(anchor.minY - h - 1, vis.minY + 8)
        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        p.orderFrontRegardless()
        p.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        Store.shared.refresh { [weak self] in self?.tick() }

        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in self?.closePanel()
            }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
    }

}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
