import Foundation

// The log is a plain Markdown file and the only source of truth.
// Knolling never rewrites the whole file from memory: every change re-reads it,
// touches one line (or inserts one), and writes it back, so hand edits survive.
// Sessions are list items and notes are nested items, so it reads as plain text
// and renders as a clean list in a Markdown app.
//
//   - 2026-09-24  09:12–10:47  research  1h 35m
//       - 09:30  [a note typed while working]
//       - 10:47  [a note logged at clock-out]
//   - 2026-09-24  11:00–       teaching  running

enum Kind: String, CaseIterable, Identifiable {
    case research, teaching
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var initial: String { String(title.prefix(1)) }
}

struct Note: Equatable {
    var time: String?   // "09:30"
    var text: String
    var display: String { time.map { "\($0)  \(text)" } ?? text }
}

struct Session: Identifiable, Equatable {
    let day: String
    let startHM: String
    var endHM: String?
    let kind: Kind
    var notes: [Note]
    let start: Date
    var end: Date?

    var id: String { "\(day) \(startHM) \(kind.rawValue)" }
    var isRunning: Bool { endHM == nil }
    var crossesMidnight: Bool { if let end { return !Calendar.current.isDate(end, inSameDayAs: start) }; return false }
    func duration(at now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}

enum Fmt {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    static let day = formatter("yyyy-MM-dd")
    static let hm = formatter("HH:mm")
    static let dayHM = formatter("yyyy-MM-dd HH:mm")
    static let weekday = formatter("EEE d MMM")

    /// "1h 05m", "42m"
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// "1:05", for the menu bar
    static func clock(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// Forgiving time entry: "8", "800", "8:00", "8am", "2:30pm", "14:30" → "HH:mm".
    static func parseTime(_ input: String) -> String? {
        var t = input.lowercased().replacingOccurrences(of: " ", with: "")
        var pm = false, am = false
        for (suffix, isPM) in [("pm", true), ("am", false), ("p", true), ("a", false)] where t.hasSuffix(suffix) {
            t.removeLast(suffix.count)
            if isPM { pm = true } else { am = true }
            break
        }
        let digits = t.replacingOccurrences(of: ":", with: "")
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isNumber) else { return nil }
        var h: Int, m: Int
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hh = Int(parts[0]), let mm = Int(parts[1]), parts[1].count == 2 else { return nil }
            h = hh; m = mm
        } else if digits.count <= 2 {
            h = Int(digits)!; m = 0
        } else {
            h = Int(digits.dropLast(2))!; m = Int(digits.suffix(2))!
        }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
}

final class LogFile {
    let url: URL

    init(url: URL) { self.url = url }

    static let header = """
    # Knolling — time log

    Research and teaching, laid out flat. Newest first. One item per session, notes nested beneath.
    Written by Knolling. Safe to edit by hand: fix a time, rewrite a note.
    Item shape: `- date  start–end  research|teaching  duration` (the duration is recomputed, not read).

    """

    private static let sessionPattern = try! NSRegularExpression(
        pattern: #"^(?:[-*]\s+)?(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s*[–—-]\s*(\d{1,2}:\d{2})?\s+(research|teaching)\b"#,
        options: [.caseInsensitive]
    )
    private static let notePattern = try! NSRegularExpression(pattern: #"^(\d{1,2}:\d{2})\s+(.*)$"#)

    private struct Block {
        var session: Session
        var line: Int          // index of the session line
        var noteLines: [Int]   // index of each note line, parallel to session.notes
        var end: Int           // index just past its last note line
    }

    // MARK: reading

    func sessions() -> [Session] { blocks(readLines()).map(\.session) }

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func blocks(_ lines: [String]) -> [Block] {
        var out: [Block] = []
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            if let m = Self.sessionPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let day = ns.substring(with: m.range(at: 1))
                let startHM = Self.pad(ns.substring(with: m.range(at: 2)))
                let endHM = m.range(at: 3).location == NSNotFound ? nil : Self.pad(ns.substring(with: m.range(at: 3)))
                guard let kind = Kind(rawValue: ns.substring(with: m.range(at: 4)).lowercased()),
                      let start = Fmt.dayHM.date(from: "\(day) \(startHM)") else { continue }
                let session = Session(day: day, startHM: startHM, endHM: endHM, kind: kind, notes: [],
                                      start: start, end: endHM.flatMap { Self.resolveEnd($0, day: day, start: start) })
                out.append(Block(session: session, line: i, noteLines: [], end: i + 1))
            } else if var last = out.last, last.end == i, line.first?.isWhitespace == true {
                // Deeper-nested lines (a record's detail, files, session) belong to the block but
                // aren't shown in the menu — the log holds the depth.
                if Self.indent(of: line) >= 8 { last.end = i + 1; out[out.count - 1] = last; continue }
                guard let note = Self.parseNote(line) else { continue }
                last.session.notes.append(note)
                last.noteLines.append(i)
                last.end = i + 1
                out[out.count - 1] = last
            }
        }
        return out
    }

    private static func parseNote(_ line: String) -> Note? {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("- ") || body.hasPrefix("* ") { body.removeFirst(2) }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let ns = body as NSString
        if let m = notePattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
            return Note(time: pad(ns.substring(with: m.range(at: 1))), text: ns.substring(with: m.range(at: 2)))
        }
        return Note(time: nil, text: body)
    }

    // MARK: writing

    func ensureExists() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try write(Self.header.components(separatedBy: "\n"))
    }

    /// New sessions go at the top, just under the header: the log reads newest first.
    func start(_ kind: Kind, at date: Date) throws {
        var lines = readLines()
        if lines.isEmpty { lines = Self.header.components(separatedBy: "\n") }
        let day = Fmt.day.string(from: date)
        let line = Self.sessionLine(day: day, start: Fmt.hm.string(from: date), end: nil, kind: kind, duration: nil)
        guard let top = blocks(lines).first else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append(line)
            try write(lines)
            return
        }
        lines.insert(contentsOf: top.session.day == day ? [line] : [line, ""], at: top.line)
        try write(lines)
    }

    /// Closes a running session. Returns the closed session, or nil if it was
    /// under a minute with no notes — a mis-tap — in which case the line is removed.
    @discardableResult
    func stop(_ id: String, at date: Date) throws -> Session? {
        var lines = readLines()
        guard let block = blocks(lines).first(where: { $0.session.id == id && $0.session.isRunning }) else { return nil }
        var s = block.session
        if date.timeIntervalSince(s.start) < 60 && s.notes.isEmpty {
            lines.remove(at: block.line)
            try write(lines)
            return nil
        }
        s.endHM = Fmt.hm.string(from: date)
        s.end = date
        lines[block.line] = Self.sessionLine(day: s.day, start: s.startHM, end: s.endHM, kind: s.kind,
                                             duration: Fmt.duration(s.duration(at: date)))
        try write(lines)
        return s
    }

    /// Rewrites a session's start and/or end ("HH:mm"). Returns the session as it now reads.
    func setTimes(_ id: String, start startHM: String, end endHM: String?) throws -> Session? {
        var lines = readLines()
        guard let block = blocks(lines).first(where: { $0.session.id == id }),
              let start = Fmt.dayHM.date(from: "\(block.session.day) \(startHM)") else { return nil }
        let s = block.session
        let end = endHM.flatMap { Self.resolveEnd($0, day: s.day, start: start) }
        lines[block.line] = Self.sessionLine(day: s.day, start: startHM, end: endHM, kind: s.kind,
                                             duration: end.map { Fmt.duration($0.timeIntervalSince(start)) })
        try write(lines)
        return blocks(lines).first { $0.line == block.line }?.session
    }

    func addNote(to id: String, _ text: String, at date: Date) throws {
        let clean = Self.oneLine(text)
        guard !clean.isEmpty else { return }
        var lines = readLines()
        guard let block = blocks(lines).first(where: { $0.session.id == id }) else { return }
        lines.insert(Self.noteLine(Note(time: Fmt.hm.string(from: date), text: clean)), at: block.end)
        try write(lines)
    }

    /// Inserts already-formatted lines (Knolling's Claude record) at the end of a session's block.
    func appendLines(to id: String, _ new: [String]) throws {
        guard !new.isEmpty else { return }
        var lines = readLines()
        guard let block = blocks(lines).first(where: { $0.session.id == id }) else { return }
        lines.insert(contentsOf: new, at: block.end)
        try write(lines)
    }

    /// Rewrites one note's text, keeping its timestamp. Empty text removes the note.
    func editNote(of id: String, at index: Int, _ text: String) throws {
        var lines = readLines()
        guard let block = blocks(lines).first(where: { $0.session.id == id }),
              block.noteLines.indices.contains(index) else { return }
        let clean = Self.oneLine(text)
        if clean.isEmpty {
            lines.remove(at: block.noteLines[index])
        } else {
            var note = block.session.notes[index]
            note.text = clean
            lines[block.noteLines[index]] = Self.noteLine(note)
        }
        try write(lines)
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func sessionLine(day: String, start: String, end: String?, kind: Kind, duration: String?) -> String {
        "- \(day)  \(start)–\(end ?? "     ")  \(kind.rawValue)  \(duration ?? "running")"
    }

    private static func noteLine(_ note: Note) -> String { "    - \(note.display)" }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// An end earlier than the start means the session crossed midnight.
    private static func resolveEnd(_ endHM: String, day: String, start: Date) -> Date? {
        guard var d = Fmt.dayHM.date(from: "\(day) \(endHM)") else { return nil }
        if d < start { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func pad(_ hm: String) -> String { hm.count == 4 ? "0" + hm : hm }
}
