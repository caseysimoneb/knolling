import Foundation

// The phone's way in. An iPhone Shortcut can't touch one line of the log, so it appends one
// line to a small inbox beside it (`knolling.inbox.md` next to `knolling.md`, or `inboxPath`),
// and Knolling folds those lines into the log in time order, through the same one-line edits
// as a tap, then removes the lines it applied. Lines it can't read are left where they are.
// No inbox file, nothing happens.
//
//   - 2026-10-14  09:10  research  in
//   - 2026-10-14  14:12  research  out
//
// So the phone can tell what's on by reading one file, Knolling keeps one line at the end of the
// inbox saying so, `now  research  in` (or `out`, with the kind used last). The Shortcut reads the
// last "kind in|out" in the file: its own newest line if the Mac hasn't folded it yet, else this one.

enum Inbox {
    struct Event { let date: Date; let kind: Kind; let isIn: Bool; let line: String }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^[-*]\s+(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s+(research|teaching)\s+(in|out)\s*$"#,
        options: [.caseInsensitive]
    )

    static func url(beside log: URL) -> URL {
        if let p = UserDefaults.standard.string(forKey: "inboxPath") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let name = log.deletingPathExtension().lastPathComponent
        return log.deletingLastPathComponent().appendingPathComponent("\(name).inbox.md")
    }

    static func parse(_ line: String) -> Event? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var hm = ns.substring(with: m.range(at: 2))
        if hm.count == 4 { hm = "0" + hm }
        guard let date = Fmt.dayHM.date(from: "\(ns.substring(with: m.range(at: 1))) \(hm)"),
              let kind = Kind(rawValue: ns.substring(with: m.range(at: 3)).lowercased()) else { return nil }
        return Event(date: date, kind: kind, isIn: ns.substring(with: m.range(at: 4)).lowercased() == "in", line: line)
    }

    /// Applies the inbox to the log. Returns the sessions it ended, so their records can be owed.
    static func fold(into log: LogFile) -> [Session] {
        let url = url(beside: log.url)
        // iCloud may keep only a placeholder on the Mac; ask for the file, and fold it next time.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let text = read(url) else { return [] }
        let events = text.components(separatedBy: "\n").compactMap(parse).sorted { $0.date < $1.date }
        guard !events.isEmpty else { return [] }

        var ended: [Session] = [], applied: [String] = []
        for e in events {
            let running = log.sessions().filter(\.isRunning).max { $0.start < $1.start }
            do {
                if let r = running, r.start > e.date {
                    // Something newer was clocked on the Mac; the phone's line is stale. Drop it.
                } else if e.isIn {
                    if let r = running {
                        if r.kind == e.kind { applied.append(e.line); continue }   // already on
                        if let s = try log.stop(r.id, at: e.date) { ended.append(s) }
                    }
                    try log.start(e.kind, at: e.date)
                } else if let r = running {
                    if let s = try log.stop(r.id, at: e.date) { ended.append(s) }
                }
                applied.append(e.line)
            } catch {
                break   // leave this line and the rest for next time
            }
        }
        remove(applied, from: url)
        return ended
    }

    /// Rewrites the `now` line when what's on has changed (on the Mac, or after a fold).
    static func syncState(_ sessions: [Session], log: URL) {
        let url = url(beside: log)
        guard let newest = sessions.max(by: { $0.start < $1.start }),
              FileManager.default.fileExists(atPath: url.path), let text = read(url) else { return }
        let state = "now  \(newest.kind.rawValue)  \(newest.isRunning ? "in" : "out")"
        var lines = text.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard lines.last != state || lines.filter({ $0.hasPrefix("now ") }).count != 1 else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &err) { u in
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return }
            var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("now ") }
            while lines.last == "" { lines.removeLast() }
            lines.append(state)
            try? (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        }
    }

    private static func read(_ url: URL) -> String? {
        var text: String?, err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            text = try? String(contentsOf: u, encoding: .utf8)
        }
        return text
    }

    /// Re-reads the inbox and removes just the applied lines, so a line the phone appended
    /// in the meantime stays.
    private static func remove(_ applied: [String], from url: URL) {
        guard !applied.isEmpty else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &err) { u in
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return }
            var lines = text.components(separatedBy: "\n")
            for line in applied { if let i = lines.firstIndex(of: line) { lines.remove(at: i) } }
            try? lines.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
        }
    }
}
