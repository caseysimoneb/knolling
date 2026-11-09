import SwiftUI

// Order, top to bottom: the year · research / teaching · the week · a note · today's sessions.
struct MenuView: View {
    var onSize: (CGSize) -> Void = { _ in }
    var openFirst = false
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshot
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @State private var open: Set<String> = []
    /// A day of this week chosen in the week strip (0 = Sunday); nil shows today.
    @State private var dayShown: Int?
    /// How many weeks back the week line shows (0 = this week), moved with ‹ and ›.
    @State private var weeksBack = UserDefaults.standard.integer(forKey: "snapshotWeeksBack")  // 0 unless set for a snapshot
    /// A deadline clicked on the year oval, shown in a popover beside it.
    @State private var deadlineShown: String? = UserDefaults.standard.string(forKey: "snapshotDeadline")
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            YearOval(now: store.now, weekStart: store.weekStart, deadlines: store.deadlines, chosen: $deadlineShown)
                .zIndex(1)  // its popover lies over what's below

            HStack(spacing: 18) {
                ForEach(Kind.allCases) { kindButton($0) }
            }

            if let p = store.pending { endPrompt(p) }

            week

            if store.pending == nil, let r = store.running {
                noteLine("a note on what you're doing") { store.addNote(to: r.id, $0) }
            }

            if let problem = store.problem ?? dictation.problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            sessionsList
            footer
        }
        .padding(18)
        .frame(width: 324)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelGlass(seed: store.weekNumber + 100 * Calendar.current.component(.year, from: store.now)))
        .onAppear { if openFirst, let first = store.today.first { open.insert(first.id) } }
        // Each time the menu opens, it starts fresh: today's sessions, every one collapsed (times only, no notes).
        .onChange(of: store.openings) { _, _ in open = []; dayShown = nil; weeksBack = 0; deadlineShown = nil }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onSize(g.size) }
                .onChange(of: g.size) { _, size in onSize(size) }
        })
    }

    // MARK: research / teaching

    /// The two kinds as words over a hairline; the live one is brighter, with a heavier rule.
    private func kindButton(_ kind: Kind) -> some View {
        let active = store.running?.kind == kind
        let subtitle: String = {
            if active, let r = store.running { return "\(Fmt.clock(r.duration(at: store.now))) — stop" }
            return store.running == nil ? "start" : "switch"
        }()
        return Button {
            keepDraft()
            store.tap(kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.rawValue).font(Face.grot(22, active ? .medium : .regular)).kerning(-0.8)
                Text(subtitle).font(Face.mono(11)).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 9)
            .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.5))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(active ? 0.95 : 0.18)).frame(height: active ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Stop \(kind.rawValue)" : "Start \(kind.rawValue)")
    }

    // MARK: the week — one tick per hour, evenly spaced within each day

    private var week: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text("week \(store.weekNumber(back: weeksBack))").font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                    // ‹ sits out in the margin, so the label stays where it always was.
                    .overlay(alignment: .leading) {
                        weekArrow("‹", shown: weeksBack < store.weeksOfLog, help: "The week before") { weeksBack += 1 }
                            .offset(x: -15)
                    }
                weekArrow("›", shown: weeksBack > 0, help: "The week after") { weeksBack -= 1 }
                Spacer()
                Text("\(Fmt.duration(store.weekTotal(back: weeksBack))) /").font(Mono.body)
                Editable(display: "\(store.weeklyGoalHours)h", editValue: "\(store.weeklyGoalHours)", width: 30) {
                    store.setWeeklyGoal($0)
                }
                .font(Mono.body)
            }
            WeekStrip(days: store.dayMinutes(back: weeksBack), today: weeksBack == 0 ? todayIndex : -1, selected: dayShown) { day in
                dayShown = ((weeksBack == 0 && day == todayIndex) || day == dayShown) ? nil : day
            }
        }
    }

    /// ‹ or ›, quiet like the label; hidden (but holding its place) when there's nowhere to go.
    private func weekArrow(_ mark: String, shown: Bool, help: String, go: @escaping () -> Void) -> some View {
        Button { dayShown = nil; open = []; go() } label: {
            Text(mark).font(Mono.label).foregroundStyle(Color.primary.opacity(0.55)).padding(.horizontal, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .disabled(!shown)
        .help(help)
    }

    // MARK: just ended

    private func endPrompt(_ p: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("log a note").font(Face.grot(13, .medium))
                Spacer()
                Text("\(p.kind.rawValue) · \(p.startHM)–\(p.endHM ?? "") · \(Fmt.duration(p.duration(at: store.now)))")
                    .font(Mono.small).foregroundStyle(.secondary).monospacedDigit()
            }
            noteLine("what happened?") { store.savePending($0) }
            HStack {
                Button("skip") {
                    dictation.cancel()
                    draft = ""
                    store.skipPending()
                }
                Spacer()
                Button("save") { submit { store.savePending($0) } }
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.plain)
            .font(Mono.label)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: note line with mic — no box, just a rule

    private func noteLine(_ placeholder: String, onSubmit: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if snapshot {
                Text(placeholder).font(Face.grot(13)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Face.grot(13))
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .onSubmit { submit(onSubmit) }
            }
            Button {
                dictation.toggle(base: draft) { draft = $0 }
            } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                    .font(Face.grot(12))
                    .foregroundStyle(dictation.isListening ? Color.red : Color.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(dictation.isListening ? "Stop dictating" : "Dictate")
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1) }
    }

    private func submit(_ action: (String) -> Void) {
        dictation.cancel()
        action(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        draft = ""
    }

    /// Anything typed but not yet entered belongs to the session it was written in.
    private func keepDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation.cancel()
        draft = ""
        guard !text.isEmpty else { return }
        if store.pending != nil { store.savePending(text) }
        else if let r = store.running { store.addNote(to: r.id, text) }
    }

    // MARK: today's sessions, collapsed until clicked

    private var todayIndex: Int { Calendar.current.component(.weekday, from: store.now) - 1 }

    /// Today's sessions, or another day's when one is chosen in the week strip.
    /// An earlier week with no day chosen shows its days, each with its hours.
    private var sessionsList: some View {
        let start = store.weekStart(back: weeksBack)
        let shown = dayShown.map { store.sessions(onDay: $0, back: weeksBack) } ?? (weeksBack == 0 ? store.today : [])
        let dayName = { (d: Int) in Calendar.current.date(byAdding: .day, value: d, to: start).map { Fmt.weekday.string(from: $0).lowercased() } ?? "" }
        let title: String = {
            if let d = dayShown { return weeksBack == 0 ? dayName(d) : "week \(store.weekNumber(back: weeksBack)) · \(dayName(d))" }
            return weeksBack == 0 ? "today" : "week \(store.weekNumber(back: weeksBack))"
        }()
        let away = dayShown != nil || weeksBack > 0
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                Spacer()
                if away {
                    Button("back to today") { dayShown = nil; weeksBack = 0; open = [] }
                        .buttonStyle(.plain).font(Mono.label).textCase(.uppercase).foregroundStyle(Color.primary.opacity(0.45))
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 3)
            if weeksBack > 0, dayShown == nil {
                let days = store.dayMinutes(back: weeksBack)
                let worked = (0..<7).filter { days[$0].research + days[$0].teaching > 0 }
                if worked.isEmpty {
                    Text("nothing that week").font(Mono.small).foregroundStyle(.tertiary).padding(.horizontal, 4)
                }
                ForEach(worked, id: \.self) { d in
                    DayRow(name: dayName(d).split(separator: " ").prefix(2).joined(separator: " "), research: days[d].research, teaching: days[d].teaching) { dayShown = d }
                }
            } else {
                if shown.isEmpty {
                    Text(dayShown == nil ? "nothing yet" : "nothing that day").font(Mono.small).foregroundStyle(.tertiary).padding(.horizontal, 4)
                }
                ForEach(shown) { s in
                    SessionRow(session: s, isOpen: open.contains(s.id)) {
                        if open.contains(s.id) { open.remove(s.id) } else { open.insert(s.id) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("open log") { store.openLog() }
            Spacer()
            Button("quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(Mono.label)
        .textCase(.uppercase)
        .foregroundStyle(.tertiary)
    }
}

/// Geist and Geist Mono, bundled in the app (Fonts/, SIL Open Font License).
enum Face {
    enum Weight { case light, regular, medium, semibold }
    static func grot(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name = ["Geist-Light", "Geist-Regular", "Geist-Medium", "Geist-SemiBold"][[Weight.light, .regular, .medium, .semibold].firstIndex(of: weight)!]
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "GeistMono-Medium" : "GeistMono-Regular", size: size)
    }
}

enum Mono {
    static let body = Face.mono(11.5)
    static let small = Face.mono(10.5)
    static let label = Face.mono(10)
}

/// The year as an ellipse, running clockwise over the top, with months placed where they're felt.
/// This week is the short lit stretch on it.
struct YearOval: View {
    let now: Date
    let weekStart: Date
    var deadlines: [Deadline] = []
    var chosen: Binding<String?> = .constant(nil)
    private let months = ["sep", "oct", "nov", "dec", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug"]

    /// Where each month begins on the ring, in degrees (0° = right, clockwise on screen), placed by hand
    /// in design/year-oval.svg: September low on the left, winter bunched along the top, summer spread
    /// along the bottom. The last value is September again, one turn on.
    static let monthStarts: [Double] = [142.2, 167.2, 217.1, 242.7, 267.0, 277.5, 289.1, 303.9, 325.2, 393.9, 433.5, 474.7, 502.2]

    /// Where each month's label sits, also placed by hand in design/year-oval.svg — centres, in points,
    /// on the 288 × 86 drawing area.
    static let labelCentres: [CGPoint] = [
        CGPoint(x: 39.5, y: 70.4), CGPoint(x: 23.9, y: 42.6), CGPoint(x: 36.2, y: 18.7), CGPoint(x: 90.2, y: 9.7),
        CGPoint(x: 151.7, y: 7.3), CGPoint(x: 173.0, y: 6.7), CGPoint(x: 195.5, y: 9.1), CGPoint(x: 219.6, y: 12.0),
        CGPoint(x: 244.6, y: 19.3), CGPoint(x: 239.4, y: 68.0), CGPoint(x: 163.6, y: 80.0), CGPoint(x: 81.0, y: 79.8)
    ]

    /// The spot on the ring for a position in months since September, in a drawing of this size.
    static func point(_ monthsFromSep: Double, in size: CGSize) -> CGPoint {
        let cx = size.width / 2, cy = size.height / 2
        let rx = size.width / 2 - 30, ry = size.height / 2 - 14
        let i = max(0, min(11, Int(monthsFromSep)))
        let f = monthsFromSep - Double(i)
        let degrees = monthStarts[i] + (monthStarts[i + 1] - monthStarts[i]) * f
        let a = CGFloat(degrees * Double.pi / 180)
        return CGPoint(x: cx + rx * CoreGraphics.cos(a), y: cy + ry * CoreGraphics.sin(a))
    }

    /// The deadlines that fit on one turn of the ring: from a month ago to eleven months on, so a date
    /// never lands on top of next year's. The first one not yet past is the next.
    private var shown: [Deadline] {
        let from = now.addingTimeInterval(-31 * 86400), to = now.addingTimeInterval(334 * 86400)
        return deadlines.filter { $0.date >= from && $0.date <= to }
    }
    private var next: Deadline? { deadlines.first { $0.date >= now } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ring
            if let n = next {
                // The next deadline, named under the oval: label, what, then the date and how far off.
                HStack(spacing: 6) {
                    Text("next").font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                    Text(n.shortWhat).font(Mono.small).foregroundStyle(Color.primary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(Self.short(n.date)) · \(Self.daysAway(n, now: now))").font(Mono.small)
                        .foregroundStyle(Color.primary.opacity(0.7)).fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { chosen.wrappedValue = chosen.wrappedValue == n.id ? nil : n.id }
                .help("Show this deadline")
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { g in
                if let d = shown.first(where: { $0.id == chosen.wrappedValue }) {
                    let p = Self.point(position(of: d.date), in: CGSize(width: g.size.width, height: 86))
                    DeadlineCard(deadline: d, now: now)
                        .frame(width: 214)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: min(max(p.x, 107), g.size.width - 107), y: p.y + 12 + 54)
                        .onTapGesture { chosen.wrappedValue = nil }
                }
            }
        }
    }

    private var ring: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let rx = size.width / 2 - 30, ry = size.height / 2 - 14
            func point(_ monthsFromSep: Double) -> CGPoint { Self.point(monthsFromSep, in: size) }
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)),
                       with: .style(Color.primary.opacity(0.42)), lineWidth: 0.9)

            let current = Int(position(of: now))
            let sx = size.width / 288, sy = size.height / 86
            for (i, m) in months.enumerated() {
                let c = Self.labelCentres[i]
                let label = Text(m).font(Face.mono(8.5))
                    .foregroundStyle(i == current ? Color.primary : Color.primary.opacity(0.52))
                ctx.draw(ctx.resolve(label), at: CGPoint(x: c.x * sx, y: c.y * sy), anchor: .center)
            }

            // Deadlines: a dot on the ring for each; the next one larger and bright, past ones faint.
            for d in shown {
                let p = point(position(of: d.date))
                let isNext = d == next, isChosen = d.id == chosen.wrappedValue
                let r: CGFloat = isNext ? 2.6 : 1.7
                let opacity = d.date < now ? 0.3 : (isNext ? 1 : 0.65)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color.primary.opacity(opacity)))
                if isChosen {
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)),
                               with: .color(.primary), lineWidth: 1)
                }
            }
            let from = position(of: weekStart), to = from + 7 / 365 * 12
            var lit = Path()
            for step in 0...12 {
                let p = point(from + (to - from) * Double(step) / 12)
                if step == 0 { lit.move(to: p) } else { lit.addLine(to: p) }
            }
            ctx.stroke(lit, with: .style(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(height: 86)
        .overlay {
            GeometryReader { g in
                // A click target on each dot (the dots themselves are too small to hit).
                ForEach(shown) { d in
                    let p = Self.point(position(of: d.date), in: g.size)
                    Circle().fill(Color.white.opacity(0.001)).frame(width: 13, height: 13)
                        .position(p)
                        .onTapGesture { chosen.wrappedValue = chosen.wrappedValue == d.id ? nil : d.id }
                        .help(d.what)
                }
            }
        }
        .accessibilityLabel("The year, with this week and my deadlines marked")
    }

    static func short(_ date: Date) -> String { Fmt.dayMonth.string(from: date).lowercased() }
    static func daysAway(_ d: Deadline, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: d.date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case ..<0: return "\(-days) days ago"
        default: return "\(days) days"
        }
    }

    /// Where a date falls on the ring, in degrees (0° = right, clockwise on screen): the same hand-placed
    /// months as the menu. The menu-bar icon uses it too.
    static func degrees(for date: Date) -> Double {
        let m = months(sinceSeptember: date)
        let i = max(0, min(11, Int(m)))
        return monthStarts[i] + (monthStarts[i + 1] - monthStarts[i]) * (m - Double(i))
    }

    /// Months elapsed since the start of September, with the day as a fraction.
    private func position(of date: Date) -> Double { Self.months(sinceSeptember: date) }

    static func months(sinceSeptember date: Date) -> Double {
        let cal = Calendar.current
        let month = cal.component(.month, from: date), day = cal.component(.day, from: date)
        let days = Double(cal.range(of: .day, in: .month, for: date)?.count ?? 30)
        return Double((month - 9 + 12) % 12) + Double(day - 1) / days
    }
}

/// Sunday to Saturday on one flat line. Each hour worked is a tick, evenly spaced within its day;
/// the hour in progress counts as a full tick. Research ticks are solid, teaching ticks hollow.
struct WeekStrip: View {
    let days: [(research: Int, teaching: Int)]
    let today: Int
    var selected: Int? = nil
    var choose: (Int) -> Void = { _ in }
    private let letters = ["s", "m", "t", "w", "t", "f", "s"]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .bottom, spacing: 2.5) {
                        ticks(minutes: days[i].research, hollow: false)
                        ticks(minutes: days[i].teaching, hollow: true)
                    }
                    .padding(.leading, 1)
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .bottomLeading)
                    .clipped()
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1) }
                    Text(letters[i]).font(Face.mono(9.5))
                        .foregroundStyle(i == today || i == selected ? .primary : .tertiary)
                        .underline(i == selected)
                }
                .contentShape(Rectangle())
                .onTapGesture { choose(i) }
                .help("Show this day's sessions")
            }
        }
        .accessibilityLabel("Hours worked each day this week")
    }

    @ViewBuilder
    private func ticks(minutes: Int, hollow: Bool) -> some View {
        // The hour you're in counts as a whole tick: 4h 36m shows five.
        let count = (minutes + 59) / 60
        ForEach(0..<count, id: \.self) { _ in
            if hollow {
                Rectangle().strokeBorder(Color.primary, lineWidth: 0.75).frame(width: 2.5, height: 12)
            } else {
                Rectangle().fill(Color.primary).frame(width: 1.5, height: 12)
            }
        }
    }
}

/// A deadline, opened from its dot: the deadline first and largest, then where and when the venue is.
struct DeadlineCard: View {
    let deadline: Deadline
    let now: Date

    var body: some View {
        let d = deadline
        VStack(alignment: .leading, spacing: 3) {
            Text(d.what).font(Face.grot(12.5, .medium)).fixedSize(horizontal: false, vertical: true)
            Text("deadline").font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                .padding(.top, 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.dayMonthYear.string(from: d.date).lowercased()).font(Face.mono(17, medium: true))
                Text(YearOval.daysAway(d, now: now)).font(Mono.small).foregroundStyle(Color.primary.opacity(0.7))
            }
            if d.estimated {
                Text("estimated · check the venue’s page").font(Mono.label).foregroundStyle(Color.primary.opacity(0.55))
            }
            if !d.place.isEmpty || !d.when.isEmpty {
                Text([d.place, d.when].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Mono.small).foregroundStyle(Color.primary.opacity(0.7)).padding(.top, 4)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.16, green: 0.27, blue: 0.45).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 9, y: 4)
    }
}

/// One day of an earlier week: its name and its hours; a click shows that day's sessions.
struct DayRow: View {
    let name: String
    let research: Int
    let teaching: Int
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(name).frame(width: 64, alignment: .leading)
            Text([research > 0 ? "research" : nil, teaching > 0 ? "teaching" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(Face.grot(12.5))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            Text(Fmt.duration(TimeInterval((research + teaching) * 60))).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(Face.grot(8, .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
        }
        .font(Mono.body)
        .monospacedDigit()
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .help("Show this day's sessions")
    }
}

/// One session. The row opens to show my notes and the numbered Claude records.
/// Times stay click-to-edit; clicking anywhere else on the row opens or closes it.
private struct SessionRow: View {
    @EnvironmentObject private var store: Store
    let session: Session
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let s = session
        let tokenNotes = s.notes.map(\.text).filter { $0.hasPrefix(Self.tokensMark) }
        let storedTokens = tokenNotes.compactMap { Fmt.parseTokens(String($0.dropFirst(Self.tokensMark.count).split(separator: " ").first ?? "")) }.reduce(0, +)
        // notes and records, numbered together in the order they're in the log
        let entries = s.notes.enumerated().filter { !$0.element.text.hasPrefix(Self.tokensMark) }
        // the small number on the row: stored at clock-out, or live for the running session
        let tokens: String? = storedTokens > 0 ? Fmt.tokens(storedTokens + (store.liveTokens[s.id] ?? 0))
            : store.liveTokens[s.id].flatMap { $0 > 0 ? Fmt.tokens($0) : nil }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Editable(display: s.startHM, width: 38) { store.setTime(of: s, start: $0) }
                    Text("–")
                    if let end = s.endHM {
                        Editable(display: end, width: 38) { store.setTime(of: s, end: $0) }
                    } else {
                        Text("now").frame(width: 38, alignment: .leading)
                    }
                }
                .frame(width: 96, alignment: .leading)
                .overlay(alignment: .leading) {
                    if s.isRunning { Circle().frame(width: 4, height: 4).offset(x: -9) }
                }
                Text(s.kind.rawValue)
                    .font(Face.grot(12.5, isOpen ? .medium : .regular))
                    .foregroundStyle(isOpen ? Color.primary : Color.primary.opacity(0.7))
                    .underline(isOpen, color: Color.primary.opacity(0.5))
                    .padding(.leading, 12)
                Spacer()
                if let tokens {
                    Text(tokens).font(Mono.small).foregroundStyle(Color.primary.opacity(0.38))
                        .padding(.trailing, 8)
                        .help("tokens: new work by Claude in this session (not counting cache reads)")
                }
                Text(Fmt.duration(s.duration(at: store.now))).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(Face.grot(8, .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .padding(.leading, 8)
            }
            .font(Mono.body)
            .monospacedDigit()
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { n, pair in
                        let isRecord = pair.element.text.hasPrefix(Self.recordMark)
                        if n > 0 { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%02d", n + 1)).font(Mono.small).foregroundStyle(.tertiary)
                            if isRecord {
                                Editable(display: String(pair.element.text.dropFirst(Self.recordMark.count)), multiline: true) {
                                    store.editNote(of: s, at: pair.offset, Self.recordMark + $0); return true
                                }
                                .font(Face.grot(12))
                                .foregroundStyle(.secondary)
                            } else {
                                // my own note: its time stays in the log, and shows on hover
                                Editable(display: pair.element.text, multiline: true) { store.editNote(of: s, at: pair.offset, $0); return true }
                                    .font(Face.grot(12))
                                    .help(pair.element.time.map { "noted at \($0)" } ?? "")
                            }
                        }
                    }
                    ForEach(tokenNotes, id: \.self) { line in
                        Text(line).font(Mono.small).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if s.isRunning {
                        if entries.isEmpty {
                            Text("records are written at clock-out").font(Mono.small).foregroundStyle(.tertiary)
                        }
                    } else {
                        // add a note after the fact; it's stamped with when you wrote it
                        AddNote(label: entries.isEmpty ? "no notes · add one" : "add a note") {
                            store.addNote(to: s.id, $0)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
        }
    }

    static let recordMark = "record · "
    static let tokensMark = "tokens · "
}

/// A faint line that becomes a note field when clicked. Return adds the note; Escape or clicking away cancels.
private struct AddNote: View {
    let label: String
    let add: (String) -> Void
    @State private var writing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if writing {
            TextField("a note on this session", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Face.grot(12))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { add(text) }
                    draft = ""; writing = false
                }
                .onExitCommand { draft = ""; writing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused { writing = false } }
                .onAppear { DispatchQueue.main.async { focused = true } }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1) }
        } else {
            Text(label)
                .font(Mono.small)
                .foregroundStyle(Color.primary.opacity(hovering ? 0.6 : 0.38))
                .underline(hovering, pattern: .dot)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { writing = true }
                .help("Add a note to this session")
        }
    }
}

/// Plain text until clicked; then a small field. Return saves, Escape or clicking away cancels.
private struct Editable: View {
    let display: String
    var editValue: String? = nil
    var width: CGFloat? = nil
    var multiline = false
    let commit: (String) -> Bool

    @State private var editing = false
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .frame(width: width)
                .focused($focused)
                .onSubmit { if commit(draft) { editing = false } }
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused { editing = false } }
                .onAppear { DispatchQueue.main.async { focused = true } }
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).padding(-2))
        } else {
            Text(display)
                .lineLimit(multiline ? 5 : 1)
                .fixedSize(horizontal: false, vertical: multiline)
                .frame(width: width, alignment: .leading)
                .underline(hovering, pattern: .dot)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture {
                    draft = editValue ?? display
                    editing = true
                }
                .help("Click to edit")
        }
    }
}
