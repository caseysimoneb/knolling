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
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            YearOval(now: store.now, weekStart: store.weekStart)

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
                Text("week \(store.weekNumber)").font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                Spacer()
                Text("\(Fmt.duration(store.weekTotal())) /").font(Mono.body)
                Editable(display: "\(store.weeklyGoalHours)h", editValue: "\(store.weeklyGoalHours)", width: 30) {
                    store.setWeeklyGoal($0)
                }
                .font(Mono.body)
            }
            WeekStrip(days: store.dayMinutes, today: Calendar.current.component(.weekday, from: store.now) - 1)
        }
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

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("today").font(Mono.label).textCase(.uppercase).kerning(0.8).foregroundStyle(Color.primary.opacity(0.55))
                .padding(.horizontal, 4).padding(.bottom, 3)
            if store.today.isEmpty {
                Text("nothing yet").font(Mono.small).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
            ForEach(store.today) { s in
                SessionRow(session: s, isOpen: open.contains(s.id)) {
                    if open.contains(s.id) { open.remove(s.id) } else { open.insert(s.id) }
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

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let rx = size.width / 2 - 30, ry = size.height / 2 - 14
            func point(_ monthsFromSep: Double) -> CGPoint {
                let i = max(0, min(11, Int(monthsFromSep)))
                let f = monthsFromSep - Double(i)
                let degrees = Self.monthStarts[i] + (Self.monthStarts[i + 1] - Self.monthStarts[i]) * f
                let a = CGFloat(degrees * Double.pi / 180)
                return CGPoint(x: cx + rx * CoreGraphics.cos(a), y: cy + ry * CoreGraphics.sin(a))
            }
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

            // To mark other dates on the year (conference deadlines, talks, the end of a term), draw them
            // here the same way: point(position(of: date)) gives each one's spot on the ring. See the
            // README, "marking dates on the year".
            let from = position(of: weekStart), to = from + 7 / 365 * 12
            var lit = Path()
            for step in 0...12 {
                let p = point(from + (to - from) * Double(step) / 12)
                if step == 0 { lit.move(to: p) } else { lit.addLine(to: p) }
            }
            ctx.stroke(lit, with: .style(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(height: 86)
        .accessibilityLabel("The year, with this week marked")
    }

    /// Months elapsed since the start of September, with the day as a fraction.
    private func position(of date: Date) -> Double {
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
                        .foregroundStyle(i == today ? .primary : .tertiary)
                }
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

/// One session. The row opens to show my notes and the numbered Claude records.
/// Times stay click-to-edit; clicking anywhere else on the row opens or closes it.
private struct SessionRow: View {
    @EnvironmentObject private var store: Store
    let session: Session
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let s = session
        let records = s.notes.enumerated().filter { $0.element.text.hasPrefix(Self.recordMark) }
        let mine = s.notes.enumerated().filter { !$0.element.text.hasPrefix(Self.recordMark) }

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
                    ForEach(mine, id: \.offset) { i, note in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let t = note.time { Text(t).font(Mono.small).foregroundStyle(.tertiary) }
                            Editable(display: note.text, multiline: true) { store.editNote(of: s, at: i, $0); return true }
                                .font(Face.grot(12))
                        }
                    }
                    ForEach(Array(records.enumerated()), id: \.offset) { n, pair in
                        if n > 0 || !mine.isEmpty { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%02d", n + 1)).font(Mono.small).foregroundStyle(.tertiary)
                            Editable(display: String(pair.element.text.dropFirst(Self.recordMark.count)), multiline: true) {
                                store.editNote(of: s, at: pair.offset, Self.recordMark + $0); return true
                            }
                            .font(Face.grot(12))
                            .foregroundStyle(.secondary)
                        }
                    }
                    if records.isEmpty && mine.isEmpty {
                        Text(s.isRunning ? "records are written at clock-out" : "no notes")
                            .font(Mono.small).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
        }
    }

    static let recordMark = "record · "
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
