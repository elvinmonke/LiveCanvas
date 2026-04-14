import Foundation
import AppKit

// MARK: - Wallpaper Item

struct WallpaperItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let url: URL
    var thumbnail: NSImage?

    init(url: URL, thumbnail: NSImage? = nil) {
        self.id = UUID()
        self.name = url.deletingPathExtension().lastPathComponent
        self.url = url
        self.thumbnail = thumbnail
    }

    static func == (lhs: WallpaperItem, rhs: WallpaperItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Display Info

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let resolution: CGSize

    var displayLabel: String {
        "\(name) (\(Int(resolution.width))x\(Int(resolution.height)))"
    }
}

// MARK: - Daemon State

struct DaemonState {
    var pid: pid_t?
    var displayID: CGDirectDisplayID
    var videoPath: String
    var isPlaying: Bool
}

// MARK: - Scale Mode

enum ScaleMode: Int, CaseIterable, Identifiable {
    case fit = 0
    case fill = 1
    case stretch = 2
    case center = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }
}
