import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct MarkdownSectionsPreview: View {
    let markdown: String

    private struct Section: Identifiable {
        let id: String
        let heading: String
        let body: String
    }

    private var sections: [Section] {
        var result: [Section] = []
        var currentHeading = ""
        var bodyLines: [String] = []
        func flush() {
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentHeading.isEmpty || !body.isEmpty else { return }
            let key = currentHeading.isEmpty ? "intro" : currentHeading
            result.append(Section(id: key, heading: currentHeading, body: body))
            bodyLines = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("## ") {
                flush()
                currentHeading = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("# ") && currentHeading.isEmpty && bodyLines.isEmpty {
                bodyLines.append(String(text.dropFirst(2)))
            } else {
                bodyLines.append(text)
            }
        }
        flush()
        if result.isEmpty {
            result.append(Section(id: "all", heading: "", body: markdown.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.heading.isEmpty {
                            Text(section.heading).font(.headline)
                        }
                        if !section.body.isEmpty {
                            if let rendered = try? AttributedString(markdown: section.body) {
                                Text(rendered)
                                    .font(.body)
                                    .foregroundStyle(section.heading.isEmpty ? Color.primary : Color.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(section.body)
                                    .font(.body)
                                    .foregroundStyle(section.heading.isEmpty ? Color.primary : Color.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PlainNoteViewer: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}

struct CollectionChat: Decodable, Identifiable {
    let id: String
    let agent: String
    let title: String
    let project: String
    let projectLabel: String?
    let first: String
    let last: String
    let preview: String?
    let titleSource: String?

    enum CodingKeys: String, CodingKey {
        case id, agent, title, project, first, last, preview
        case titleSource = "title_source"
        case projectLabel = "project_label"
    }

    var projectHint: String {
        if !project.isEmpty { return project }
        return projectLabel ?? ""
    }

    var activityLabel: String {
        func parse(_ value: String) -> Date? {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }
        guard let start = parse(first), let end = parse(last) else { return first }
        let day = DateFormatter()
        day.dateFormat = Calendar.current.component(.year, from: start) == Calendar.current.component(.year, from: end) ? "d MMM" : "d MMM yyyy"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let startTime = clock.string(from: start), endTime = clock.string(from: end)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(day.string(from: start)) · \(startTime)" + (startTime == endTime ? "" : "-\(endTime)")
        }
        return "\(day.string(from: start)) · \(startTime) - \(day.string(from: end)) · \(endTime)"
    }

}

private struct CollectionReply: Decodable {
    let chats: [CollectionChat]
    let path: String?
    let count: Int?
    let summary: String?
    let categories: String?
    let notice: String?
    let handoff: String?
    let empty: Bool?
    let synthesizer: String?
}

private struct NoteReply: Decodable {
    let path: String
    let saved: Bool
}

/// The menu panel reads this so Update now can spin without owning the collect window.
final class CollectionActivity: ObservableObject {
    static let shared = CollectionActivity()
    @Published var updating = false
}

final class CollectionModel: ObservableObject {
    @Published var start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
    @Published var end = Calendar.current.startOfDay(for: Date())
    static let allAgents = ["claude", "codex", "cursor", "grok"]
    @Published var agents: Set<String> = Set(allAgents)
    @Published var availableAgents: Set<String> = Set(allAgents)
    @Published var chats: [CollectionChat] = []
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var error: String?
    @Published var savedPath: String?
    @Published var savedCount = 0
    @Published var saveNotice = ""
    @Published var hasDraft = false
    @Published var viewedNote: String?
    @Published var summary = ""
    @Published var categories = ""
    @Published var handoff = ""
    @Published var notice: String?
    @Published var draftView = "Summary"
    @Published var editing = false
    @Published var busyLabel = ""

    var activeDraft: String {
        switch draftView {
        case "Categories": return categories
        case "Agent draft": return handoff
        default: return summary
        }
    }
    var draftBinding: Binding<String> {
        Binding(get: { self.activeDraft }, set: { value in
            if self.draftView == "Summary" { self.summary = value }
            else if self.draftView == "Categories" { self.categories = value }
            else { self.handoff = value }
            self.savedPath = nil
            self.saveNotice = ""
        })
    }

    var validation: String? {
        if start > end { return "The start date must be on or before the end date." }
        if (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) > 365 {
            return "Choose a range of up to 366 days."
        }
        if agents.isEmpty { return "Switch on at least one agent." }
        return nil
    }

    private func dateString(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }

    var rangeLabel: String { "\(dateString(start)) to \(dateString(end))" }

    func refreshAgents() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = [scrollHome + "/agents_list.sh"]
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
            let text = String(data: data, encoding: .utf8) ?? ""
            let found = Set(text.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "|")
                guard parts.count == 2, parts[1] == "1" else { return nil }
                return String(parts[0])
            })
            DispatchQueue.main.async {
                self.availableAgents = found.isEmpty ? Set(Self.allAgents) : found
                self.agents = self.agents.intersection(self.availableAgents)
                if self.agents.isEmpty { self.agents = self.availableAgents }
            }
        }
    }

    func updateToday() {
        let today = Calendar.current.startOfDay(for: Date())
        start = today
        end = today
        refreshAgents()
        CollectionActivity.shared.updating = true
        guard !busy, validation == nil else {
            CollectionActivity.shared.updating = false
            return
        }
        var request: [String: Any] = [
            "operation": "list",
            "start": dateString(start), "end": dateString(end),
            "agents": agents.intersection(availableAgents).sorted()
        ]
        invoke("history_collect.py", request: request, label: "Finding today's chats…") { (reply: CollectionReply) in
            if reply.empty == true || reply.chats.isEmpty {
                self.discardDraft()
                self.chats = []
                self.selected = []
                self.error = "No chats found for today across the enabled agents."
                CollectionActivity.shared.updating = false
                CollectionWindows.showChats()
                return
            }
            self.chats = reply.chats
            self.selected = Set(reply.chats.map(\.id))
            self.previewSelection()
        }
    }

    func previewSelection() {
        guard !busy, validation == nil, !selected.isEmpty else {
            CollectionActivity.shared.updating = false
            return
        }
        let request: [String: Any] = [
            "operation": "preview",
            "start": dateString(start), "end": dateString(end),
            "agents": agents.sorted(), "selected": selected.sorted()
        ]
        invoke("history_collect.py", request: request, label: "Summarizing…") { (reply: CollectionReply) in
            try self.applyPreview(reply)
        }
    }

    private func fallbackSummary(from chats: [CollectionChat]) -> String {
        guard !chats.isEmpty else { return "# Summary\n\nNo chat text was returned." }
        var lines = ["# Summary", "", "Local overview from \(chats.count) chat(s).", ""]
        for chat in chats.prefix(12) {
            let excerpt = (chat.preview ?? "No excerpt").prefix(120)
            lines.append("- **\(chat.title)** (\(chat.agent)): \(excerpt)")
        }
        return lines.joined(separator: "\n")
    }

    private func fallbackCategories(from chats: [CollectionChat]) -> String {
        guard !chats.isEmpty else { return "# Categories\n\nNothing to categorize." }
        var lines = ["# By chat", ""]
        for chat in chats.prefix(12) {
            lines.append("- \(chat.title) · \(chat.agent)")
            lines.append("  - Done: see preview")
            lines.append("  - Blockers: not recorded")
            lines.append("  - Next: not recorded")
        }
        return lines.joined(separator: "\n")
    }

    private func applyPreview(_ reply: CollectionReply) throws {
        var summaryText = reply.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var categoriesText = reply.categories?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if summaryText.isEmpty { summaryText = fallbackSummary(from: reply.chats) }
        if categoriesText.isEmpty { categoriesText = fallbackCategories(from: reply.chats) }
        viewedNote = nil
        summary = summaryText
        categories = categoriesText
        handoff = reply.handoff ?? ""
        notice = reply.notice
        savedCount = reply.chats.count
        savedPath = nil
        saveNotice = ""
        draftView = "Summary"
        editing = false
        hasDraft = true
        CollectionActivity.shared.updating = false
        CollectionWindows.showChats()
    }

    private func invoke<Reply: Decodable>(_ script: String, request: [String: Any], label: String,
                                          completion: @escaping (Reply) throws -> Void) {
        guard !busy else { return }
        guard let input = try? JSONSerialization.data(withJSONObject: request) else {
            error = "Could not prepare the request."
            CollectionActivity.shared.updating = false
            return
        }
        busy = true
        busyLabel = label
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", scrollHome + "/core/" + script]
            var environment = ProcessInfo.processInfo.environment
            environment["SCROLLBACK_HOME"] = scrollHome
            environment["BEAT_HOME"] = scrollHome
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            task.environment = environment
            let stdin = Pipe(), output = Pipe()
            task.standardInput = stdin
            task.standardOutput = output
            task.standardError = output
            do {
                try task.run()
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                guard task.terminationStatus == 0 else {
                    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NSError(domain: "Scrollback", code: 1, userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Could not finish. Try again."])
                }
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                DispatchQueue.main.async {
                    self.busy = false
                    do { try completion(reply) }
                    catch {
                        self.error = error.localizedDescription
                        CollectionActivity.shared.updating = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.error = error.localizedDescription
                    CollectionActivity.shared.updating = false
                }
            }
        }
    }

    func run(collect: Bool) {
        guard !busy, validation == nil, !collect || !selected.isEmpty else { return }
        var request: [String: Any] = [
            "operation": collect ? "preview" : "list",
            "start": dateString(start), "end": dateString(end), "agents": agents.sorted()
        ]
        if collect { request["selected"] = selected.sorted() }
        invoke("history_collect.py", request: request, label: collect ? "Summarizing…" : "Finding chats…") { (reply: CollectionReply) in
            if collect && reply.empty == true {
                self.discardDraft()
                self.chats = []
                self.selected = []
                self.savedCount = 0
                CollectionWindows.showChats()
                return
            }
            if !collect && reply.chats.isEmpty {
                self.discardDraft()
                self.chats = []
                self.selected = []
                self.savedCount = 0
                CollectionWindows.showChats()
                return
            }
            if collect {
                try self.applyPreview(reply)
            } else {
                self.viewedNote = nil
                self.chats = reply.chats
                self.selected = Set(reply.chats.map(\.id))
                self.hasDraft = false
                CollectionWindows.showChats()
            }
        }
    }

    func discardDraft() {
        guard !busy else { return }
        hasDraft = false
        viewedNote = nil
        summary = ""
        categories = ""
        handoff = ""
        notice = nil
        editing = false
        savedPath = nil
        saveNotice = ""
        error = nil
    }

    func openSavedNote() {
        guard !busy, let path = savedPath else { return }
        busy = true
        busyLabel = "Opening note…"
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = URL(fileURLWithPath: path)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else {
                    throw NSError(domain: "Scrollback", code: 4, userInfo: [NSLocalizedDescriptionKey: "This note is too large for the lightweight viewer (2 MB maximum)."])
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                DispatchQueue.main.async {
                    self.viewedNote = text
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func saveDraft(append: Bool) {
        guard !busy, !activeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = activeDraft
        let view = draftView
        let panel: NSSavePanel
        if append {
            let open = NSOpenPanel()
            open.canChooseDirectories = false
            open.canChooseFiles = true
            open.allowsMultipleSelection = false
            open.prompt = "Append"
            panel = open
        } else {
            let save = NSSavePanel()
            save.nameFieldStringValue = "\(dateString(start))-\(view.lowercased()).md"
            save.canCreateDirectories = true
            panel = save
        }
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.title = append ? "Append \(view)" : "Save \(view)"
        panel.message = "Only the current \(view.lowercased()) view will be \(append ? "appended" : "saved")."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.invoke("note_store.py", request: ["operation": append ? "append" : "save", "path": url.path, "text": text], label: "Saving…") { (reply: NoteReply) in
                self.savedPath = reply.path
                self.saveNotice = reply.saved ? "Saved to \(url.lastPathComponent)" : "Already in \(url.lastPathComponent)"
            }
        }
    }
}

private struct CollectionCalendar: View {
    @Binding var selection: Date
    let choose: (Date) -> Void
    @State private var month: Date
    private let calendar = Calendar.current

    init(selection: Binding<Date>, choose: @escaping (Date) -> Void) {
        _selection = selection
        self.choose = choose
        _month = State(initialValue: selection.wrappedValue)
    }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
    }

    private var days: [Date] {
        collectionCalendarDays(month: month, calendar: calendar)
    }

    private var weekdays: [String] {
        let labels = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { labels[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private func moveMonth(_ offset: Int) {
        if let value = calendar.date(byAdding: .month, value: offset, to: monthStart) { month = value }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(monthStart, format: .dateTime.month(.wide).year())
                    .font(.headline)
                Spacer()
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[index]).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, height: 24).accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in
                    let selected = calendar.isDate(day, inSameDayAs: selection)
                    let sameMonth = calendar.isDate(day, equalTo: monthStart, toGranularity: .month)
                    Button { choose(calendar.startOfDay(for: day)) } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Color.white : sameMonth ? Color.primary : Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(selected ? greenDeep : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                if calendar.isDateInToday(day) && !selected {
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.4))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider()
            HStack {
                Text(selection, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Today") { choose(calendar.startOfDay(for: Date())) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 272)
    }
}

private struct CollectionDateButton: View {
    let title: String
    @Binding var selection: Date
    @State private var showingCalendar = false

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: selection)
    }

    var body: some View {
        LabeledContent(title) {
            Button(dateLabel) { showingCalendar.toggle() }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(title), \(dateLabel)")
                .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                    CollectionCalendar(selection: $selection) { date in
                        selection = date
                        showingCalendar = false
                    }
                }
        }
    }
}

struct CollectionDatesView: View {
    @ObservedObject var model: CollectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Collect").font(.title2.weight(.semibold))
                Text("Dates and agents, then pick chats.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Section("Dates") {
                    CollectionDateButton(title: "From", selection: $model.start)
                    CollectionDateButton(title: "To", selection: $model.end)
                }
                Section("Agents") {
                    ForEach(CollectionModel.allAgents, id: \.self) { agent in
                        Toggle(agent.capitalized, isOn: Binding(
                            get: { model.agents.contains(agent) },
                            set: { on in
                                if on { model.agents.insert(agent) }
                                else { model.agents.remove(agent) }
                            }))
                            .toggleStyle(.switch)
                            .disabled(!model.availableAgents.contains(agent))
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(model.busy)
            Text("Both dates count. Your chat files are not changed.")
                .font(.caption2).foregroundStyle(.secondary)
            if let message = model.validation ?? model.error {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.busyLabel.isEmpty ? "Working…" : model.busyLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Find chats") { model.run(collect: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.validation != nil)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

struct CollectionChatsView: View {
    @ObservedObject var model: CollectionModel
    private func chatRow(_ chat: CollectionChat) -> some View {
        Toggle(isOn: Binding(
            get: { model.selected.contains(chat.id) },
            set: { on in
                if on { model.selected.insert(chat.id) }
                else { model.selected.remove(chat.id) }
            })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.title).font(.body.weight(.medium)).lineLimit(2)
                        .help(chat.projectHint.isEmpty ? chat.title : "\(chat.title)\n\(chat.projectHint)")
                    Spacer(minLength: 0)
                    Text(chat.agent.capitalized).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                if let preview = chat.preview, !preview.isEmpty {
                    Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(chat.activityLabel).font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 6)
        }
        .toggleStyle(.checkbox)
    }

    var body: some View {
        Group {
            if let note = model.viewedNote {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("Back to overview") { model.viewedNote = nil }
                        Spacer()
                        Text(URL(fileURLWithPath: model.savedPath ?? "").lastPathComponent).font(.headline)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy all note text").accessibilityLabel("Copy all note text")
                    }.padding(20)
                    Divider()
                    PlainNoteViewer(text: note).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.hasDraft { CollectionDraftView(model: model) }
            else { chatSelection }
        }
        .frame(minWidth: 650, minHeight: 460)
    }

    private var chatSelection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose chats").font(.title2.weight(.semibold))
                    Text(model.rangeLabel).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.selected = Set(model.chats.map(\.id)) } label: {
                    Image(systemName: "checkmark.square")
                }.help("Select all chats").accessibilityLabel("Select all chats").disabled(model.busy || model.chats.isEmpty)
                Button { model.selected.removeAll() } label: {
                    Image(systemName: "square")
                }.help("Deselect all chats").accessibilityLabel("Deselect all chats").disabled(model.busy || model.selected.isEmpty)
                Button("Change dates & agents") { CollectionWindows.showDates() }
                    .disabled(model.busy)
            }.padding(20)
            Divider()
            if model.chats.isEmpty {
                VStack(spacing: 8) {
                    Text("No matching chats").font(.headline)
                    Text("Try another date range or switch on another agent.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.chats.sorted { $0.last > $1.last }) { chat in
                        chatRow(chat)
                    }
                }.scrollIndicators(.hidden).disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let message = model.error {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Review an overview here before choosing whether to save it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? model.busyLabel : "\(model.selected.count) of \(model.chats.count) selected")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Just see it") { model.run(collect: true) }
                        .disabled(model.busy || model.selected.isEmpty)
                    Button("Collect") { model.run(collect: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.selected.isEmpty)
                }
            }.padding(20)
        }
        .frame(minWidth: 650, minHeight: 460)
    }
}


private struct CollectionDraftView: View {
    @ObservedObject var model: CollectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Overview").font(.title2.weight(.semibold))
                    Text("\(model.savedCount) chats · \(model.rangeLabel)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { copyCurrentView() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy all text in this view").accessibilityLabel("Copy all text in this view")
                Button("Discard") { model.discardDraft() }
                    .help("Discard this overview and return to chats")
            }.padding(20).disabled(model.busy)
            HStack {
                Picker("View", selection: $model.draftView) {
                    Text("Summary").tag("Summary")
                    Text("Categories").tag("Categories")
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                Spacer()
                if !model.handoff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Copy evidence for agent") { copyHandoff() }
                        .disabled(model.busy)
                }
                Toggle("Edit", isOn: $model.editing).toggleStyle(.switch)
            }.padding(.horizontal, 20).padding(.bottom, 14).disabled(model.busy)
            if let notice = model.notice, !notice.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()
            if model.editing {
                TextEditor(text: model.draftBinding)
                    .font(.body).padding(12).disabled(model.busy)
            } else {
                MarkdownSectionsPreview(markdown: model.activeDraft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text(model.busyLabel).foregroundStyle(.secondary)
                    } else {
                        Text(model.saveNotice.isEmpty ? "Save or append the current \(model.draftView.lowercased()) view." : model.saveNotice)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.savedPath != nil {
                        Button("Open file now") { model.openSavedNote() }
                    }
                    Button("Append…") { model.saveDraft(append: true) }
                        .disabled(model.activeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Save new…") { model.saveDraft(append: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.activeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.scrollIndicators(.hidden).disabled(model.busy)
            }.padding(20)
        }
    }

    private func copyCurrentView() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.activeDraft, forType: .string)
    }

    private func copyHandoff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.handoff, forType: .string)
    }
}

enum CollectionWindows {
    private static let model = CollectionModel()
    private static var dates: NSWindow?
    private static var chats: NSWindow?

    private static func show(_ window: NSWindow) {
        dismissScrollbackMenuPanel?()
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func updateToday() {
        guard !model.busy else { return }
        model.error = nil
        model.updateToday()
    }

    static func showDates() {
        guard !model.busy else { return }
        chats?.orderOut(nil)
        model.error = nil
        model.refreshAgents()
        if dates == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 478, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Collect chats"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CollectionDatesView(model: model))
            dates = window
        }
        show(dates!)
    }

    static func showChats() {
        dates?.orderOut(nil)
        if chats == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Select chats to collect"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CollectionChatsView(model: model))
            chats = window
        }
        show(chats!)
    }
}
