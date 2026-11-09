import Foundation

/// A date I'm working toward, from a plain file I keep (the `deadlinesPath` setting), one per line:
/// `- 2026-12-07  ICED27 full paper | Hamburg | 16–20 Aug 2027`. A `~` before the date means estimated.
/// Lines that don't start with a date are ignored, so the file can carry its own notes.
struct Deadline: Identifiable, Equatable {
    let date: Date
    let what: String
    let place: String
    let when: String
    let estimated: Bool
    var id: String { Fmt.day.string(from: date) + " " + what }
    /// The name without its parenthesis, for the one line under the oval.
    var shortWhat: String { what.components(separatedBy: " (").first ?? what }

    /// The deadlines in the file, in date order; none if the setting is off or the file is missing.
    static func load() -> [Deadline] {
        guard let path = UserDefaults.standard.string(forKey: "deadlinesPath"), !path.isEmpty,
              let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { parse(String($0)) }.sorted { $0.date < $1.date }
    }

    static func parse(_ line: String) -> Deadline? {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
        let estimated = s.hasPrefix("~")
        if estimated { s.removeFirst() }
        guard s.count > 10, let date = Fmt.day.date(from: String(s.prefix(10))) else { return nil }
        let parts = s.dropFirst(10).split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let what = parts.first ?? ""
        guard !what.isEmpty else { return nil }
        func part(_ i: Int) -> String { i < parts.count && parts[i] != "—" && parts[i] != "-" ? parts[i] : "" }
        // Noon, so a deadline sits in the middle of its day on the ring.
        let noon = Calendar.current.date(byAdding: .hour, value: 12, to: date) ?? date
        return Deadline(date: noon, what: what, place: part(1), when: part(2), estimated: estimated)
    }
}
