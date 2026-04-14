import SwiftUI

@main
struct LiveCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var wallpaperManager = WallpaperManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(wallpaperManager)
                .frame(minWidth: 780, minHeight: 520)
                .background(Color(hex: 0x111111))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 560)

        Settings {
            SettingsView()
                .environmentObject(wallpaperManager)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "LiveCanvas")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open LiveCanvas", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Design Tokens

enum LCColors {
    static let background = Color(hex: 0x111111)
    static let surface = Color(hex: 0x1A1A1A)
    static let surfaceLight = Color(hex: 0x222222)
    static let border = Color(hex: 0x2A2A2A)
    static let textPrimary = Color(hex: 0xE5E5E5)
    static let textSecondary = Color(hex: 0x888888)
    static let accent = Color(hex: 0xC49A6C)
    static let accentSubtle = Color(hex: 0xC49A6C).opacity(0.12)
}
