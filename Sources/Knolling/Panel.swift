import AppKit
import Combine
import SwiftUI

/// Knolling's own menu: a status item and a transparent panel, so the menu can be clear glass
/// over the desktop instead of the system's grey menu window.
final class PanelController: NSObject, NSWindowDelegate {
    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = KnollingPanel()
    private var host: NSHostingView<AnyView>!
    private var watching: AnyCancellable?
    private var closedAt = Date.distantPast

    init(store: Store) {
        self.store = store
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        host = NSHostingView(rootView: AnyView(
            MenuView(onSize: { [weak self] in self?.fit($0) }).environmentObject(store)
        ))
        panel.contentView = host
        panel.delegate = self
        updateButton()
        watching = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
    }

    /// Off the clock: a small knolled grid. Live: "R 1:12". A trailing dot means an hourly check-in went unseen.
    private func updateButton() {
        guard let button = item.button else { return }
        if let r = store.running {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: "\(r.kind.initial) \(Fmt.clock(r.duration(at: store.now)))\(store.nudgeUnseen ? " ·" : "")",
                attributes: [.font: NSFont(name: "GeistMono-Regular", size: 12.5) ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)])
        } else {
            button.title = ""
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Knolling")
            image?.isTemplate = true
            button.image = image
        }
    }

    @objc private func toggle() {
        if panel.isVisible { panel.orderOut(nil); store.menuClosed(); return }
        // A click on the status item first takes focus from the open panel; don't reopen it.
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        store.opened()
        place(size: host.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.orderOut(nil)
        store.menuClosed()
        closedAt = Date()
    }

    private func fit(_ size: CGSize) {
        guard panel.isVisible, size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func place(size: CGSize) {
        guard let buttonWindow = item.button?.window else { return }
        let b = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = b.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: b.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

final class KnollingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Nearly clear glass behind the menu, sampling the desktop, so a little of what's behind shows through.
/// It always renders its light version, while the menu's text stays in the system appearance.
struct GlassBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear   // barely frosted: the field above does the work, the windows behind just show through
            glass.cornerRadius = cornerRadius
            glass.appearance = NSAppearance(named: .aqua)
            return glass
        }
        let frost = NSVisualEffectView()
        frost.blendingMode = .behindWindow
        frost.material = .popover
        frost.state = .active
        frost.appearance = NSAppearance(named: .aqua)
        frost.wantsLayer = true
        frost.layer?.cornerRadius = cornerRadius
        frost.layer?.masksToBounds = true
        return frost
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Rendering to an image for review: system glass can't be captured, so it's left out.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The menu's glass: this week's blue field, mostly opaque, over nearly clear glass — so it always
/// has a designed backdrop, whatever is behind it — with a soft, feathered edge.
struct PanelGlass: View {
    let seed: Int
    @Environment(\.snapshotMode) private var snapshot
    static let radius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack(alignment: .top) {
            if snapshot { Color(red: 0.55, green: 0.62, blue: 0.72) } else { GlassBackdrop(cornerRadius: Self.radius) }
            if let field = BlueField.image(seed: seed) {
                Color.clear
                    .overlay(alignment: .top) { Image(nsImage: field).resizable().scaledToFill() }
                    .clipped()
                    .opacity(0.84)
            }
            shape.fill(LinearGradient(colors: [Color(red: 0.05, green: 0.17, blue: 0.33).opacity(0.10),
                                               Color(red: 0.04, green: 0.14, blue: 0.28).opacity(0.18)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [Color.white.opacity(0.20), .clear],
                                      center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 240))
            // soft edge: a feathered inner glow and a faint rim, no hard outline
            shape.stroke(Color.white.opacity(0.18), lineWidth: 10).blur(radius: 7)
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.05), Color.white.opacity(0.14)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
        }
        .clipShape(shape)
    }
}
