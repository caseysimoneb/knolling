import AppKit
import ServiceManagement
import UserNotifications

final class Store: ObservableObject {
    static let shared = Store()

    let log: LogFile
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var now = Date()
    /// A session that just ended and is waiting for its "Log a note".
    @Published private(set) var pending: Session?
    /// An hourly check-in went out and the menu hasn't been opened since.
    @Published private(set) var nudgeUnseen = false
    /// Counts openings of the menu, so the menu can start fresh each time (sessions collapsed).
    @Published private(set) var openings = 0
    @Published var problem: String?
    /// Tokens so far for the running session (new work), refreshed on open and every five minutes.
    @Published private(set) var liveTokens: [String: Int] = [:]
    /// Dates I'm working toward, drawn on the year oval (from the `deadlinesPath` file).
    @Published private(set) var deadlines: [Deadline] = []

    private var timer: Timer?
    private var pinnedNow = false
    private var nudged: (id: String, hours: Int)?

    private init() {
        let path = UserDefaults.standard.string(forKey: "logPath")
            ?? NSHomeDirectory() + "/Documents/Knolling/knolling.md"
        log = LogFile(url: URL(fileURLWithPath: path))
        // For screenshots: `-snapshotNow "2026-09-24 14:14"` pins the clock.
        if let pinned = UserDefaults.standard.string(forKey: "snapshotNow"), let d = Fmt.dayHM.date(from: pinned) {
            now = d
            pinnedNow = true
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    var running: Session? { sessions.filter(\.isRunning).max { $0.start < $1.start } }

    var today: [Session] {
        let day = Fmt.day.string(from: now)
        return sessions.filter { $0.day == day || $0.isRunning }.sorted { $0.start < $1.start }
    }

    /// Sunday 00:00 through Saturday 23:59.
    var weekStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    }

    private var weekCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        cal.minimumDaysInFirstWeek = 1
        return cal
    }

    /// The Sunday that starts the week `back` weeks before this one (0 = this week).
    func weekStart(back: Int) -> Date {
        weekCalendar.date(byAdding: .day, value: -7 * back, to: weekStart) ?? weekStart
    }

    /// Week of the year, counted Sunday to Saturday.
    var weekNumber: Int { weekNumber(back: 0) }
    func weekNumber(back: Int) -> Int { weekCalendar.component(.weekOfYear, from: weekStart(back: back)) }

    /// How many weeks back the log goes: the week of its first session.
    var weeksOfLog: Int {
        guard let first = sessions.map(\.start).min() else { return 0 }
        let days = weekCalendar.dateComponents([.day], from: weekCalendar.startOfDay(for: first), to: weekStart).day ?? 0
        return max(0, (days + 6) / 7)
    }

    /// Minutes worked on each day of a week, Sunday first, by kind.
    var dayMinutes: [(research: Int, teaching: Int)] { dayMinutes(back: 0) }
    func dayMinutes(back: Int) -> [(research: Int, teaching: Int)] {
        (0..<7).map { offset in
            let mine = sessions(onDay: offset, back: back)
            func total(_ k: Kind) -> Int { Int(mine.filter { $0.kind == k }.reduce(0) { $0 + $1.duration(at: now) } / 60) }
            return (total(.research), total(.teaching))
        }
    }

    /// The sessions on one day of a week (0 = Sunday), in time order.
    func sessions(onDay offset: Int, back: Int = 0) -> [Session] {
        guard let day = weekCalendar.date(byAdding: .day, value: offset, to: weekStart(back: back)) else { return [] }
        return sessions.filter { weekCalendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
    }

    var thisWeek: [Session] { sessions.filter { $0.start >= weekStart }.sorted { $0.start < $1.start } }

    func weekTotal(_ kind: Kind? = nil, back: Int = 0) -> TimeInterval {
        let start = weekStart(back: back), end = weekStart(back: back - 1)
        return sessions.filter { $0.start >= start && (back == 0 || $0.start < end) && (kind == nil || $0.kind == kind) }
            .reduce(0) { $0 + $1.duration(at: now) }
    }

    /// Research + teaching hours to aim for each week.
    var weeklyGoalHours: Int {
        let v = UserDefaults.standard.integer(forKey: "weeklyGoalHours")
        return v > 0 ? v : 40
    }

    func setWeeklyGoal(_ input: String) -> Bool {
        guard let h = Int(input.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "hH "))),
              (1...100).contains(h) else { return false }
        UserDefaults.standard.set(h, forKey: "weeklyGoalHours")
        objectWillChange.send()
        return true
    }

    // MARK: actions

    /// Tapping a kind starts it; tapping the live one stops it; tapping the other switches.
    func tap(_ kind: Kind) {
        now = Date()
        attempt {
            if let r = running {
                let ended = try log.stop(r.id, at: now)
                if let ended { Scribe.owe(ended, store: self) }
                // Notes always go to what's running. "Log a note" for an ended session appears only
                // on a full clock-out; switching goes straight to the new session's note field.
                pending = r.kind == kind ? ended : nil
                if r.kind == kind { return }
            }
            try log.start(kind, at: now)
        }
    }

    func addNote(to id: String, _ text: String) {
        attempt { try log.addNote(to: id, text, at: Date()) }
    }

    func savePending(_ text: String) {
        if let p = pending { addNote(to: p.id, text) }
        pending = nil
    }

    func skipPending() { pending = nil }

    /// "Log a note" only lasts until the menu closes, so a later note can't land on a session that
    /// ended earlier; the next time the menu opens, the note field belongs to what's running.
    func menuClosed() { pending = nil }

    /// Scribe's record of the Claude sessions that ran during a session. Finds the session even if
    /// its times were edited while the record was owed, and never writes a record twice.
    func appendRecord(for owed: Scribe.Owed, _ lines: [String]) {
        reload()
        let target = sessions.first { $0.id == owed.id }
            ?? sessions.first { $0.kind.rawValue == owed.kind && !$0.isRunning
                && $0.start < owed.end && ($0.end ?? owed.end) > owed.start }
        // never write the same record twice — but a record moved in by hand doesn't block a new one
        let firstLine = lines.first?.trimmingCharacters(in: .whitespaces).dropFirst(2) ?? ""
        guard let target, !target.notes.contains(where: { $0.text == firstLine }) else { return }
        attempt { try log.appendLines(to: target.id, lines) }
    }

    func editNote(of s: Session, at index: Int, _ text: String) {
        attempt { try log.editNote(of: s.id, at: index, text) }
    }

    /// Hand-correct a start or end time from the menu. Returns false if the input doesn't make sense.
    func setTime(of s: Session, start: String? = nil, end: String? = nil) -> Bool {
        guard let newStart = start.map(Fmt.parseTime) ?? s.startHM,
              let startDate = Fmt.dayHM.date(from: "\(s.day) \(newStart)") else {
            problem = "Try a time like 8:00, 830, or 2pm."; return false
        }
        var newEnd = s.endHM
        if let end {
            guard let e = Fmt.parseTime(end) else { problem = "Try a time like 8:00, 830, or 2pm."; return false }
            newEnd = e
        }
        if s.isRunning, startDate > Date() { problem = "Start can't be in the future."; return false }
        if let newEnd, newEnd < newStart, !s.crossesMidnight {
            problem = "End is before start."; return false
        }
        var updated: Session?
        attempt { updated = try log.setTimes(s.id, start: newStart, end: newEnd) }
        if let updated {
            if nudged?.id == s.id { nudged = (updated.id, nudged!.hours) }
            if pending?.id == s.id { pending = updated }
        }
        return updated != nil
    }

    /// From the notification's Stop button: stops only if that session is still the live one.
    func stop(ifRunning id: String) {
        if let r = running, r.id == id { tap(r.kind) }
    }

    func opened() {
        openings += 1
        nudgeUnseen = false
        if !pinnedNow { now = Date() }
        foldInbox()
        reload()
        refreshLiveTokens()
    }

    func openLog() {
        attempt { try log.ensureExists() }
        NSWorkspace.shared.open(log.url)
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private func refreshLiveTokens() {
        guard Scribe.tokensEnabled, let r = running else { return }
        let start = r.start, id = r.id
        Scribe.tokenQueue.async {
            let n = Scribe.usage(from: start, to: Date()).new
            DispatchQueue.main.async { self.liveTokens = [id: n] }
        }
    }

    // MARK: internals

    private func attempt(_ body: () throws -> Void) {
        do { try body(); problem = nil } catch { problem = "Couldn't write the log: \(error.localizedDescription)" }
        reload()
    }

    private func reload() { // picks up hand edits too
        sessions = log.sessions(); deadlines = Deadline.load()
        if !pinnedNow { Inbox.syncState(sessions, log: log.url) }
    }

    /// Clock-ins and outs from the phone (see Inbox.swift). Not while the clock is pinned for a snapshot.
    private func foldInbox() {
        guard !pinnedNow else { return }
        for ended in Inbox.fold(into: log) { Scribe.owe(ended, store: self) }
    }

    private var ticks = 0

    private func tick() {
        if !pinnedNow { now = Date() }
        foldInbox()
        reload()
        checkNudge()
        ticks += 1
        if ticks % 30 == 0 { Scribe.settle(self); refreshLiveTokens() }   // every five minutes
    }

    /// Once per full hour of a running session. Ignoring it changes nothing.
    private func checkNudge() {
        guard let r = running else { nudged = nil; nudgeUnseen = false; return }
        guard UserDefaults.flag("hourlyCheckIn", default: true) else { return }
        let hours = Int(r.duration(at: now) / 3600)
        guard hours >= 1 else { return }
        if let n = nudged, n.id == r.id, n.hours >= hours { return }
        nudged = (r.id, hours)
        nudgeUnseen = true
        Notifier.nudge(r, hours: hours)
    }
}

enum Notifier {
    static let category = "nudge"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let stop = UNNotificationAction(identifier: "stop", title: "Stop")
        let note = UNTextInputNotificationAction(identifier: "note", title: "Add note", options: [],
                                                 textInputButtonTitle: "Add", textInputPlaceholder: "What's happening?")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [stop, note], intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func nudge(_ s: Session, hours: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(s.kind.title) · \(hours)h"
        content.body = "Still running. Nothing to do if you're still at it."
        content.categoryIdentifier = category
        content.userInfo = ["id": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nudge", content: content, trigger: nil))
    }
}
