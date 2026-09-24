import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct KnollingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu lives in its own panel (Panel.swift); the app has no windows of its own.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Knolling --snapshot out.png`: render the menu to an image for review, then quit.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        Notifier.setUp(delegate: self)
        panel = PanelController(store: Store.shared)
        // A clock should always be there: start at login, set once on first run (undo in System Settings → Login Items).
        if !UserDefaults.standard.bool(forKey: "registeredForLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "registeredForLogin")
        }
    }

    @MainActor private func snapshot(to path: String) {
        let view = MenuView(openFirst: true)
            .environmentObject(Store.shared)
            .environment(\.colorScheme, .dark)
            .environment(\.snapshotMode, true)
            .padding(24)
            .background(Color(red: 0.93, green: 0.93, blue: 0.91))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? ""
        let text = (response as? UNTextInputNotificationResponse)?.userText
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "stop": Store.shared.stop(ifRunning: id)
            case "note": if let text { Store.shared.addNote(to: id, text) }
            default: break
            }
            completionHandler()
        }
    }
}
