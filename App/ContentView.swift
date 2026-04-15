import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var manager: WallpaperManager
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            HStack(spacing: 0) {
                sidebar
                Divider()
                    .background(LCColors.border)
                detailPanel
            }

            // Bottom bar
            bottomBar
        }
        .background(LCColors.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(manager)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Library")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LCColors.textPrimary)
                Spacer()
                Button(action: { manager.pickFolder() }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                        .foregroundColor(LCColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Choose wallpaper folder")

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(LCColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(LCColors.border)

            // Wallpaper list
            if manager.wallpapers.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(manager.wallpapers) { item in
                            WallpaperRow(
                                item: item,
                                isSelected: manager.selectedWallpaper?.id == item.id
                            )
                            .onTapGesture {
                                manager.selectedWallpaper = item
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 220)
        .background(LCColors.surface)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 24, weight: .thin))
                .foregroundColor(LCColors.textSecondary.opacity(0.5))
            Text("No videos")
                .font(.system(size: 12))
                .foregroundColor(LCColors.textSecondary)
            Text("Choose a folder to get started")
                .font(.system(size: 11))
                .foregroundColor(LCColors.textSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let wallpaper = manager.selectedWallpaper {
                // Preview
                previewArea(wallpaper)

                Divider()
                    .background(LCColors.border)

                // Controls
                controlsArea
            } else {
                noSelectionView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LCColors.background)
    }

    private func previewArea(_ wallpaper: WallpaperItem) -> some View {
        VStack(spacing: 0) {
            if let thumbnail = wallpaper.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LCColors.border, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LCColors.surfaceLight)
                    .overlay(
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 32, weight: .ultraLight))
                            .foregroundColor(LCColors.textSecondary.opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LCColors.border, lineWidth: 1)
                    )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlsArea: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                // Display picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display")
                        .font(.system(size: 11))
                        .foregroundColor(LCColors.textSecondary)

                    Picker("", selection: $manager.selectedDisplay) {
                        ForEach(manager.displays) { display in
                            Text(display.displayLabel)
                                .tag(Optional(display))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                // Scale mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scale")
                        .font(.system(size: 11))
                        .foregroundColor(LCColors.textSecondary)

                    Picker("", selection: Binding(
                        get: { manager.scaleMode },
                        set: { manager.updateScaleMode($0) }
                    )) {
                        ForEach(ScaleMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                Spacer()
            }

            HStack(spacing: 20) {
                // Volume
                VStack(alignment: .leading, spacing: 6) {
                    Text("Volume")
                        .font(.system(size: 11))
                        .foregroundColor(LCColors.textSecondary)

                    HStack(spacing: 8) {
                        Image(systemName: manager.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundColor(LCColors.textSecondary)
                            .frame(width: 14)

                        Slider(
                            value: Binding(
                                get: { manager.volume },
                                set: { manager.updateVolume($0) }
                            ),
                            in: 0...1
                        )
                        .tint(LCColors.accent)
                        .frame(width: 140)
                    }
                }

                Spacer()

                // Action button
                Button(action: { manager.togglePlayback() }) {
                    HStack(spacing: 6) {
                        Image(systemName: manager.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(manager.isPlaying ? "Stop" : "Set Wallpaper")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(manager.isPlaying ? LCColors.background : LCColors.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(manager.isPlaying ? LCColors.accent : LCColors.surfaceLight)
                    )
                    .overlay(
                        Capsule()
                            .stroke(manager.isPlaying ? Color.clear : LCColors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(LCColors.surface)
    }

    private var noSelectionView: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundColor(LCColors.textSecondary.opacity(0.3))
            Text("Select a wallpaper")
                .font(.system(size: 13))
                .foregroundColor(LCColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Circle()
                .fill(manager.isPlaying ? LCColors.accent : LCColors.textSecondary.opacity(0.3))
                .frame(width: 6, height: 6)

            Text(manager.statusText)
                .font(.system(size: 11))
                .foregroundColor(LCColors.textSecondary)

            Spacer()

            Text("\(manager.wallpapers.count) video\(manager.wallpapers.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(LCColors.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(LCColors.surface)
        .overlay(
            Divider().background(LCColors.border),
            alignment: .top
        )
    }
}

// MARK: - Wallpaper Row

struct WallpaperRow: View {
    let item: WallpaperItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(LCColors.surfaceLight)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 10))
                                .foregroundColor(LCColors.textSecondary.opacity(0.4))
                        )
                }
            }
            .frame(width: 48, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LCColors.border, lineWidth: 0.5)
            )

            // Name
            Text(item.name)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? LCColors.textPrimary : LCColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? LCColors.accentSubtle : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? LCColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

