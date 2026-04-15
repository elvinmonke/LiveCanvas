import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var manager: WallpaperManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(LCColors.textPrimary)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LCColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(LCColors.surfaceLight)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .background(LCColors.border)

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Wallpaper folder
                    settingsSection("Wallpaper Folder") {
                        HStack(spacing: 10) {
                            Text(manager.wallpaperFolder?.path ?? "No folder selected")
                                .font(.system(size: 12))
                                .foregroundColor(
                                    manager.wallpaperFolder != nil
                                        ? LCColors.textPrimary
                                        : LCColors.textSecondary
                                )
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(LCColors.surfaceLight)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(LCColors.border, lineWidth: 1)
                                )

                            Button("Browse") {
                                manager.pickFolder()
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundColor(LCColors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LCColors.surfaceLight)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(LCColors.border, lineWidth: 1)
                            )
                        }
                    }

                    Divider()
                        .background(LCColors.border)

                    // Behavior
                    settingsSection("Behavior") {
                        VStack(spacing: 12) {
                            settingsToggle(
                                "Launch at login",
                                subtitle: "Start LiveCanvas when you log in",
                                isOn: $manager.launchAtLogin
                            )

                            settingsToggle(
                                "Auto-pause on fullscreen",
                                subtitle: "Pause playback when an app goes fullscreen",
                                isOn: $manager.autoPauseFullscreen
                            )

                            settingsToggle(
                                "Battery mode",
                                subtitle: "Reduce framerate to save power on battery",
                                isOn: $manager.batteryMode
                            )
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 440, height: 380)
        .background(LCColors.background)
        .preferredColorScheme(.dark)
        .onChange(of: manager.launchAtLogin) { manager.savePreferences() }
        .onChange(of: manager.autoPauseFullscreen) { manager.savePreferences() }
        .onChange(of: manager.batteryMode) { manager.savePreferences() }
    }

    // MARK: - Components

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(LCColors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            content()
        }
    }

    private func settingsToggle(
        _ title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(LCColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(LCColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(LCColors.accent)
                .labelsHidden()
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LCColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LCColors.border, lineWidth: 1)
        )
    }
}

