import Foundation

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
        DemoHistory.preview ? DemoHistory.screenshotRuns() : load()
    }
}

/// Synthetic history is used only when the app is launched with --demo.
enum DemoHistory {
    static let preview = CommandLine.arguments.contains("--demo")

    static func screenshotDays() -> [Day] {
        let counts = [9, 15, 12, 12, 15, 10, 11]
        return counts.enumerated().compactMap { index, count in
            guard let date = Calendar.current.date(byAdding: .day, value: index - 6, to: Date()) else { return nil }
            return Day(id: "demo-\(index)", date: date, collected: count)
        }
    }

    static func screenshotRuns() -> [Run] {
        screenshotDays().reversed().map { day in
            Run(at: day.date, chats: day.collected, trigger: "demo", ok: true, new: nil)
        }
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

    static func loadForPanel() -> [Day] {
        DemoHistory.preview ? DemoHistory.screenshotDays() : load()
    }
}
