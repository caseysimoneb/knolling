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
    @Published var problem: String?

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

    /// Week of the year, counted Sunday to Saturday.
    var weekNumber: Int { weekCalendar.component(.weekOfYear, from: now) }

    /// Minutes worked on each day of this week, Sunday first, by kind.
    var dayMinutes: [(research: Int, teaching: Int)] {
        (0..<7).map { offset in
            guard let day = weekCalendar.date(byAdding: .day, value: offset, to: weekStart) else { return (0, 0) }
            let mine = sessions.filter { weekCalendar.isDate($0.start, inSameDayAs: day) }
            func total(_ k: Kind) -> Int { Int(mine.filter { $0.kind == k }.reduce(0) { $0 + $1.duration(at: now) } / 60) }
            return (total(.research), total(.teaching))
        }
    }

    var thisWeek: [Session] { sessions.filter { $0.start >= weekStart }.sorted { $0.start < $1.start } }

    func weekTotal(_ kind: Kind? = nil) -> TimeInterval {
        thisWeek.filter { kind == nil || $0.kind == kind }.reduce(0) { $0 + $1.duration(at: now) }
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
                pending = try log.stop(r.id, at: now)
                if let ended = pending { Scribe.record(ended, into: self) }
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

    /// Scribe's record of the Claude sessions that ran during a session.
    func appendRecord(to id: String, _ lines: [String]) {
        attempt { try log.appendLines(to: id, lines) }
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
        nudgeUnseen = false
        if !pinnedNow { now = Date() }
        reload()
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

    // MARK: internals

    private func attempt(_ body: () throws -> Void) {
        do { try body(); problem = nil } catch { problem = "Couldn't write the log: \(error.localizedDescription)" }
        reload()
    }

    private func reload() { sessions = log.sessions() } // picks up hand edits too

    private func tick() {
        if !pinnedNow { now = Date() }
        reload()
        checkNudge()
    }

    /// Once per full hour of a running session. Ignoring it changes nothing.
    private func checkNudge() {
        guard let r = running else { nudged = nil; nudgeUnseen = false; return }
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
