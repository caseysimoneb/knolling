import Foundation

/// At clock-out, reads the Claude Code sessions I actively used during the session that just ended —
/// optionally limited to one Claude account — and adds a record under it in the log:
///
///     - record · I specified [what I set out to make or decide].
///         - Claude built [what Claude made at my direction].
///         - file: projects/example/notes.md
///         - folder: projects/example
///
/// What counts: a session with at least one message *I* sent inside the clocked-in window; only that
/// slice of it is read. The file and folder lines come straight from the transcripts and point to my
/// local files — never to the Claude session itself, which may not last. The sentences
/// are Claude's, written to a style guide you own (RECORD-STYLE.md), via the `claude` CLI.
/// Off by default. No UI; if anything fails, the log is left as it was.
///
/// Settings (`defaults write <bundle id> <key> <value>`):
///   claudeNotes          true to turn the record on
///   claudeEmail          only write records while the `claude` CLI is signed in as this account
///   claudeAccountFolder  only read desktop-app sessions from this account's folder in
///                        ~/Library/Application Support/Claude/claude-code-sessions/
///   recordStylePath      your own style guide (defaults to the one bundled in the app)
enum Scribe {
    static var accountEmail: String? { UserDefaults.standard.string(forKey: "claudeEmail") }
    static var accountFolder: String? { UserDefaults.standard.string(forKey: "claudeAccountFolder") }
    static var stylePath: String? {
        UserDefaults.standard.string(forKey: "recordStylePath")
            ?? Bundle.main.path(forResource: "RECORD-STYLE", ofType: "md")
    }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "claudeNotes") as? Bool ?? false }

    /// True when no account is required, or the CLI is signed in to the required one.
    private static var cliAllowed: Bool {
        guard let required = accountEmail else { return true }
        return cliAccount()?.lowercased() == required.lowercased()
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let queue = DispatchQueue(label: "knolling.scribe", qos: .utility)

    static func record(_ session: Session, into store: Store) {
        guard enabled, let end = session.end else { return }
        let start = session.start
        queue.async {
            let lines = recordLines(from: start, to: end)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { store.appendRecord(to: session.id, lines) }
        }
    }

    /// The formatted lines for one clocked-in window (empty if no session counts).
    static func recordLines(from start: Date, to end: Date) -> [String] {
        let found = activity(from: start, to: end)
        let canWrite = cliAllowed
        let style = stylePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        var lines: [String] = []
        for a in found {
            var written: Written?
            if canWrite, let style {
                // a slow or busy moment shouldn't cost the record: try up to three times
                for attempt in 0..<3 where written == nil {
                    if attempt > 0 { Thread.sleep(forTimeInterval: 20) }
                    written = write(a, style: style, from: start, to: end)
                }
            }
            if let w = written {
                lines.append("    - record · \(w.glance)")
                lines += w.entries.map { "        - \($0)" }
                if a.stillWorking {
                    lines.append("        - Claude was still working when I clocked out" + (w.stillWorking.map { ": \($0)" } ?? "."))
                }
            } else {
                lines.append("    - record · (no written record) Claude session used while clocked in.")
                if a.stillWorking { lines.append("        - Claude was still working when I clocked out.") }
            }
            let files = a.files.map(display)
            lines += files.prefix(10).map { "        - file: \($0)" }
            if files.count > 10 { lines.append("        - file: …and \(files.count - 10) more") }
            if let folder = a.folder { lines.append("        - folder: \(display(folder))") }
        }
        return lines
    }

    // MARK: finding the sessions I used

    struct Activity {
        let id: String
        let title: String
        var files: [String]       // absolute paths, in order first touched
        var excerpt: [String]     // who said what, briefly
        var stillWorking: Bool    // Claude was mid-task at clock-out
        var cwd: String?

        /// Where the work lives locally: the folder the touched files share, else where the session ran.
        var folder: String? {
            let parents = files.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
            if var common = parents.first {
                for p in parents.dropFirst() {
                    common = Array(zip(common, p).prefix { $0 == $1 }.map(\.0))
                }
                let path = "/" + common.joined(separator: "/")
                if common.count > 3 { return path } // deeper than the home folder's Desktop
            }
            return cwd
        }
    }

    private static func activity(from start: Date, to end: Date) -> [Activity] {
        let (listed, other) = desktopSessions()
        let projects = URL(fileURLWithPath: home + "/.claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }

        var out: [Activity] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                if other.contains(id) { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= start,
                      let a = read(file, id: id, from: start, to: end, title: listed[id], allowUnlisted: cliAllowed)
                else { continue }
                out.append(a)
            }
        }
        return out
    }

    /// Desktop-app sessions: id → title for the allowed account (every account, if none is set),
    /// and the ids belonging to any other account.
    private static func desktopSessions() -> (listed: [String: String], other: Set<String>) {
        let root = home + "/Library/Application Support/Claude/claude-code-sessions"
        let fm = FileManager.default
        var listed: [String: String] = [:], other = Set<String>()
        for account in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let accountPath = root + "/" + account
            for org in (try? fm.contentsOfDirectory(atPath: accountPath)) ?? [] {
                let orgPath = accountPath + "/" + org
                for name in (try? fm.contentsOfDirectory(atPath: orgPath)) ?? [] where name.hasPrefix("local_") {
                    guard let data = fm.contents(atPath: orgPath + "/" + name),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = json["cliSessionId"] as? String else { continue }
                    if accountFolder == nil || account == accountFolder { listed[id] = (json["title"] as? String) ?? "Claude session" }
                    else { other.insert(id) }
                }
            }
        }
        return (listed, other)
    }

    /// Reads one transcript's slice inside the window. It counts only if I sent a message in that slice.
    /// Desktop sessions must belong to the allowed account; terminal sessions count only while the CLI is allowed.
    private static func read(_ file: URL, id: String, from start: Date, to end: Date,
                             title: String?, allowUnlisted: Bool) -> Activity? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var files: [String] = [], excerpt: [String] = [], entrypoint: String?, cwd: String?
        var iSpoke = false
        var last: (stamp: Date, finishedReply: Bool)?

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if entrypoint == nil { entrypoint = entry["entrypoint"] as? String }
            if let c = entry["cwd"] as? String, (entry["timestamp"] as? String).flatMap(iso.date(from:)).map({ $0 >= start && $0 <= end }) ?? false {
                cwd = c
            } else if cwd == nil { cwd = entry["cwd"] as? String }
            // Messages I send while Claude is mid-reply are stored as queued attachments, not user turns.
            if entry["type"] as? String == "attachment",
               let att = entry["attachment"] as? [String: Any], att["type"] as? String == "queued_command",
               (att["origin"] as? [String: Any])?["kind"] as? String ?? "human" == "human",
               let stamp = (entry["timestamp"] as? String).flatMap(iso.date(from:)), stamp >= start, stamp <= end {
                let said = (att["prompt"] as? String)
                    ?? (att["prompt"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
                let line = "ME: " + clip(said)
                if !said.isEmpty, !excerpt.contains(line) { iSpoke = true; excerpt.append(line) }
                continue
            }
            guard let type = entry["type"] as? String, type == "user" || type == "assistant",
                  let stamp = (entry["timestamp"] as? String).flatMap(iso.date(from:)),
                  stamp >= start, stamp <= end,
                  let message = entry["message"] as? [String: Any] else { continue }
            let sidechain = entry["isSidechain"] as? Bool ?? false
            let blocks = message["content"] as? [[String: Any]] ?? []
            let isToolResult = blocks.contains { $0["type"] as? String == "tool_result" }

            if type == "user", !sidechain, !isToolResult, isHuman(entry, message) {
                iSpoke = true
                let said = (message["content"] as? String)
                    ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                if !said.isEmpty { excerpt.append("ME: " + clip(said)) }
            }
            if !sidechain {
                let usesTool = blocks.contains { $0["type"] as? String == "tool_use" }
                last = (stamp, type == "assistant" && !usesTool)
            }
            guard type == "assistant" else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    guard !sidechain, let t = block["text"] as? String else { break }
                    excerpt.append("CLAUDE: " + clip(t))
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "Bash", let command = input["command"] as? String {
                        for path in Self.changedPaths(in: command, base: cwd, from: start, to: end) where keep(path) && !files.contains(path) {
                            files.append(path)
                            excerpt.append("[Claude changed \(display(path)) with a shell command]")
                        }
                    }
                    if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name),
                       let path = (input["file_path"] ?? input["notebook_path"]) as? String,
                       keep(path), !files.contains(path) {
                        files.append(path)
                        excerpt.append("[Claude \(name == "Write" ? "wrote" : "edited") \(display(path))]")
                    }
                default: break
                }
            }
        }
        guard iSpoke else { return nil }
        if title == nil {
            guard allowUnlisted, entrypoint == "cli" else { return nil }
        }
        // Mid-task at clock-out: the last thing in the window wasn't a finished reply, and it was recent.
        let stillWorking = last.map { !$0.finishedReply && end.timeIntervalSince($0.stamp) < 300 } ?? false
        return Activity(id: id, title: title ?? "Claude Code (terminal)", files: files, excerpt: excerpt, stillWorking: stillWorking, cwd: cwd)
    }

    /// A message I typed, as opposed to one the app injected (task notices, attachments, reminders).
    private static func isHuman(_ entry: [String: Any], _ message: [String: Any]) -> Bool {
        if let origin = entry["origin"] as? [String: Any] { return origin["kind"] as? String == "human" }
        if entry["isMeta"] as? Bool == true { return false }
        let text = (message["content"] as? String)
            ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        return !text.trimmingCharacters(in: .whitespaces).hasPrefix("<")
    }

    // MARK: writing the record

    struct Written { let glance: String; let entries: [String]; let stillWorking: String? }

    private static func write(_ a: Activity, style: String, from start: Date, to end: Date) -> Written? {
        guard let claude = cliPath(), !a.excerpt.isEmpty else { return nil }
        var body = a.excerpt.joined(separator: "\n")
        if body.count > 20_000 { body = String(body.prefix(4_000)) + "\n…\n" + String(body.suffix(16_000)) }
        let prompt = """
        You are writing one entry in my lab notebook. Follow this style guide exactly; it is mine and it governs:

        <style>
        \(style)
        </style>

        Below is the part of one Claude Code session that happened while I was clocked in, \(Fmt.hm.string(from: start))–\(Fmt.hm.string(from: end)).
        "ME:" lines are what I said; "CLAUDE:" lines are Claude's replies; bracketed lines are files Claude wrote or edited.
        \(a.stillWorking ? "Claude was still mid-task when I clocked out." : "")

        <transcript>
        \(body)
        </transcript>

        Before answering, check every entry against the guide and rewrite any that fail:
        1. It starts with "I" or "Claude" and states exactly one act.
        2. Thinking (reading, planning, framing, making sense, discussing ideas) gets ONE high-level entry at most,
           saying what it was for. Ideas, corrections, and turns along the way are left out.
        3. Made things (built, drafted, saved, organized, revised) are itemized, one per entry.
        4. No project or tool names, no file names, and no private shorthand or phrases borrowed from the
           transcript (words I use casually in conversation that an outside reader wouldn't know). Describe plainly.
        5. Ideas Claude proposed are credited: "Claude proposed…; I agreed."
        6. Each entry is at most 20 words. At most four entries besides the glance.
        7. Only research and teaching work; leave out incidental computer housekeeping.
        8. The glance says what the time served, in words an outside reader would understand.
        9. No personal, family, or health details, even if the session touched them — leave that act out.
        10. The author is "I". Never refer to the person as she, her, he, him, they, or "the user".

        Reply with only a JSON object, no code fence:
        {"glance": "<one entry>", "entries": ["<entry>", ...], "still_working": \(a.stillWorking ? "\"<what Claude was doing, briefly>\"" : "null")}
        Do not include file, folder, or session names; file and folder lines are added separately.
        """

        let scratch = home + "/Library/Caches/knolling-scribe"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", "--model", "sonnet", "--tools", "", "--no-session-persistence", "--strict-mcp-config"]
        p.currentDirectoryURL = URL(fileURLWithPath: scratch)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        input.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 300) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }

        let raw = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8)) as? [String: Any],
              let glance = (json["glance"] as? String).map(oneLine), !glance.isEmpty else { return nil }
        return Written(glance: glance,
                       entries: (json["entries"] as? [String] ?? []).map(oneLine).filter { !$0.isEmpty },
                       stillWorking: (json["still_working"] as? String).map(oneLine))
    }

    // MARK: helpers

    /// Paths named in a shell command that point to files modified during the window — edits made
    /// with scripts rather than the editing tools. Files only read are left out by the time check.
    static func changedPaths(in command: String, base: String?, from start: Date, to end: Date) -> [String] {
        var tokens: [String] = [], current = "", quote: Character?
        for ch in command {
            if let q = quote { if ch == q { quote = nil } else { current.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch.isWhitespace || ";|&()<>".contains(ch) {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        let fm = FileManager.default
        let logPath = UserDefaults.standard.string(forKey: "logPath")
        var out: [String] = []
        func expand(_ t: String) -> String { t.hasPrefix("~/") ? home + t.dropFirst(1) : t }
        var dir = base
        var previous = ""
        for raw in tokens {
            defer { previous = raw }
            if previous == "cd" { dir = expand(raw); continue }
            // assignments like F=~/x or p='Sources/x.swift' name the path after the '='
            let token = String(raw.split(separator: "=", omittingEmptySubsequences: false).last ?? "")
            let path: String
            if token.hasPrefix("~/") || token.hasPrefix(home + "/") {
                path = expand(token)
            } else if let dir, !token.hasPrefix("-"), token.contains("/") || token.contains(".") {
                path = dir + "/" + token
            } else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, path != logPath,
                  !path.contains("/.git/"),
                  let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified >= start, modified <= end.addingTimeInterval(300) else { continue }
            if !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// The email the `claude` CLI is signed in with.
    private static func cliAccount() -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.claude.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    private static func cliPath() -> String? {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Leave out Claude's own memory and scratch files.
    private static func keep(_ path: String) -> Bool {
        !path.hasPrefix(home + "/.claude/") && !path.hasPrefix("/private/tmp/") && !path.hasPrefix("/tmp/")
    }

    /// Paths relative to the Desktop when they sit on it; otherwise relative to home.
    private static func display(_ path: String) -> String {
        if path.hasPrefix(home + "/Desktop/") { return String(path.dropFirst(home.count + "/Desktop/".count)) }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func clip(_ s: String) -> String {
        let one = oneLine(s)
        return one.count > 600 ? String(one.prefix(600)) + "…" : one
    }
}
