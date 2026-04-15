import Foundation
import AppKit
import AVFoundation
import Combine

class WallpaperManager: ObservableObject {

    // MARK: - Published State

    @Published var wallpapers: [WallpaperItem] = []
    @Published var selectedWallpaper: WallpaperItem?
    @Published var selectedDisplay: DisplayInfo?
    @Published var displays: [DisplayInfo] = []
    @Published var scaleMode: ScaleMode = .fill
    @Published var volume: Float = 0.5
    @Published var isPlaying: Bool = false
    @Published var statusText: String = "Idle"
    @Published var wallpaperFolder: URL?

    // Settings
    @Published var launchAtLogin: Bool = false
    @Published var autoPauseFullscreen: Bool = true
    @Published var batteryMode: Bool = false

    // MARK: - Private

    private var daemonStates: [CGDirectDisplayID: DaemonState] = [:]
    private let defaults = UserDefaults.standard
    private let sharedDefaults = UserDefaults(suiteName: "com.elvin.livecanvas")
    private let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private let thumbnailCache = NSCache<NSURL, NSImage>()

    // MARK: - Init

    init() {
        loadPreferences()
        enumerateDisplays()
        if let folder = wallpaperFolder {
            scanFolder(folder)
        }
    }

    // MARK: - Display Enumeration

    func enumerateDisplays() {
        displays = NSScreen.screens.enumerated().map { index, screen in
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            let size = screen.frame.size
            return DisplayInfo(
                id: displayID,
                name: name,
                resolution: CGSize(width: size.width * (screen.backingScaleFactor), height: size.height * (screen.backingScaleFactor))
            )
        }
        if selectedDisplay == nil {
            selectedDisplay = displays.first
        }
    }

    // MARK: - Folder Scanning

    func scanFolder(_ url: URL) {
        wallpaperFolder = url
        defaults.set(url.path, forKey: "lc_wallpaperFolder")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { return }

            var items: [WallpaperItem] = []
            while let fileURL = enumerator.nextObject() as? URL {
                if self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    let thumbnail = self.generateThumbnail(for: fileURL)
                    items.append(WallpaperItem(url: fileURL, thumbnail: thumbnail))
                }
            }
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self.wallpapers = items
                if self.selectedWallpaper == nil {
                    self.selectedWallpaper = items.first
                }
            }
        }
    }

    // MARK: - Thumbnail Generation

    func generateThumbnail(for url: URL) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            thumbnailCache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Daemon Management

    func setWallpaper() {
        guard let wallpaper = selectedWallpaper,
              let display = selectedDisplay else { return }

        // Kill existing daemon for this display
        stopWallpaper(for: display.id)

        // Spawn new daemon process
        let daemonPath = Bundle.main.bundlePath + "/Contents/MacOS/wallpaperdaemon"
        let args = [
            daemonPath,
            wallpaper.url.path,
            String(volume),
            String(scaleMode.rawValue),
            String(display.id)
        ]

        var pid: pid_t = 0
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        let result = posix_spawn(&pid, daemonPath, nil, nil, argv, nil)

        if result == 0 {
            daemonStates[display.id] = DaemonState(
                pid: pid,
                displayID: display.id,
                videoPath: wallpaper.url.path,
                isPlaying: true
            )
            isPlaying = true
            statusText = "Playing on \(display.name)"

            // Write active video path for the screen saver to read
            sharedDefaults?.set(wallpaper.url.path, forKey: "lc_activeVideoPath")
            defaults.set(wallpaper.url.path, forKey: "lc_activeVideoPath")
            sharedDefaults?.synchronize()

            // Install LiveCanvas as the active screen saver for lock screen
            installScreenSaver()

            savePreferences()
        } else {
            statusText = "Failed to start daemon"
        }

        // Post notification to daemon
        postNotification(name: "com.livecanvas.play")
    }

    func stopWallpaper(for displayID: CGDirectDisplayID? = nil) {
        if let id = displayID, let state = daemonStates[id] {
            if let pid = state.pid {
                kill(pid, SIGTERM)
            }
            daemonStates.removeValue(forKey: id)
        } else {
            // Stop all
            for (_, state) in daemonStates {
                if let pid = state.pid {
                    kill(pid, SIGTERM)
                }
            }
            daemonStates.removeAll()
        }

        let anyPlaying = daemonStates.values.contains { $0.isPlaying }
        isPlaying = anyPlaying
        statusText = anyPlaying ? statusText : "Idle"

        postNotification(name: "com.livecanvas.stop")
    }

    func togglePlayback() {
        if isPlaying {
            stopWallpaper(for: selectedDisplay?.id)
        } else {
            setWallpaper()
        }
    }

    // MARK: - Screen Saver Installation

    private func installScreenSaver() {
        // Copy the .saver bundle from the app bundle to ~/Library/Screen Savers/
        let saverSource = Bundle.main.bundlePath + "/Contents/Resources/LiveCanvas.saver"
        let saverDest = NSHomeDirectory() + "/Library/Screen Savers/LiveCanvas.saver"

        let fm = FileManager.default
        if fm.fileExists(atPath: saverSource) {
            try? fm.removeItem(atPath: saverDest)
            try? fm.copyItem(atPath: saverSource, toPath: saverDest)
        }

        // Set LiveCanvas as the active screen saver via defaults
        let ssDefaults = UserDefaults(suiteName: "com.apple.screensaver")
        ssDefaults?.set("LiveCanvas", forKey: "moduleDict.moduleName")
        ssDefaults?.set(saverDest, forKey: "moduleDict.path")
        ssDefaults?.set(0, forKey: "moduleDict.type")  // 0 = .saver bundle
        ssDefaults?.synchronize()

        // Also write directly to com.apple.screensaver
        defaults.set(["moduleName": "LiveCanvas", "path": saverDest, "type": 0],
                     forKey: "moduleDict")
    }

    // MARK: - Darwin Notifications

    private func postNotification(name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    // MARK: - Volume Update

    func updateVolume(_ newVolume: Float) {
        volume = newVolume
        defaults.set(newVolume, forKey: "lc_volume")
        postNotification(name: "com.livecanvas.volumeChanged")
    }

    func updateScaleMode(_ mode: ScaleMode) {
        scaleMode = mode
        defaults.set(mode.rawValue, forKey: "lc_scaleMode")
        postNotification(name: "com.livecanvas.scaleModeChanged")
    }

    // MARK: - Preferences

    private func loadPreferences() {
        if let path = defaults.string(forKey: "lc_wallpaperFolder") {
            wallpaperFolder = URL(fileURLWithPath: path)
        }
        volume = defaults.object(forKey: "lc_volume") as? Float ?? 0.5
        scaleMode = ScaleMode(rawValue: defaults.integer(forKey: "lc_scaleMode")) ?? .fill
        launchAtLogin = defaults.bool(forKey: "lc_launchAtLogin")
        autoPauseFullscreen = defaults.object(forKey: "lc_autoPauseFullscreen") as? Bool ?? true
        batteryMode = defaults.bool(forKey: "lc_batteryMode")
    }

    func savePreferences() {
        defaults.set(volume, forKey: "lc_volume")
        defaults.set(scaleMode.rawValue, forKey: "lc_scaleMode")
        defaults.set(launchAtLogin, forKey: "lc_launchAtLogin")
        defaults.set(autoPauseFullscreen, forKey: "lc_autoPauseFullscreen")
        defaults.set(batteryMode, forKey: "lc_batteryMode")

        // Save per-display assignments
        var assignments: [String: String] = [:]
        for (displayID, state) in daemonStates {
            assignments[String(displayID)] = state.videoPath
        }
        defaults.set(assignments, forKey: "lc_displayAssignments")
    }

    // MARK: - Folder Picker

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing video wallpapers"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            scanFolder(url)
        }
    }
}
