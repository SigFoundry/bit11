import AppKit
import SwiftUI

@main
struct bit11App: App {
    @StateObject private var workspace = ZipWorkspace()
    @StateObject private var localizationSettings = AppLocalizationSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(localizationSettings)
                .environment(\.locale, localizationSettings.locale)
                .frame(minWidth: 980, minHeight: 620)
                .id(localizationSettings.refreshID)
        }
        .commands {
            ZipCommands(workspace: workspace, localizationSettings: localizationSettings)
            AboutCommands(localizationSettings: localizationSettings)
            SettingsCommands(localizationSettings: localizationSettings)
        }

        Window(L10n.text("menu.settings"), id: "settings") {
            SettingsView()
                .environmentObject(localizationSettings)
                .environment(\.locale, localizationSettings.locale)
                .id(localizationSettings.refreshID)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 220)

        Window(L10n.text("about.window_title"), id: "about") {
            AboutView()
                .environmentObject(localizationSettings)
                .environment(\.locale, localizationSettings.locale)
                .id(localizationSettings.refreshID)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 360)
    }
}

private struct AboutCommands: Commands {
    @ObservedObject var localizationSettings: AppLocalizationSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = localizationSettings.refreshID
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("about.menu_title")) {
                openWindow(id: "about")
            }
        }
    }
}


private struct SettingsCommands: Commands {
    @ObservedObject var localizationSettings: AppLocalizationSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = localizationSettings.refreshID
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("menu.settings")) {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var localizationSettings: AppLocalizationSettings

    var body: some View {
        Form {
            Picker(L10n.text("settings.language"), selection: $localizationSettings.selectedLanguage) {
                ForEach(AppLocalizationSettings.LanguageOption.allCases) { option in
                    Text(L10n.text(option.labelKey)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var aboutIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 256, height: 256)
        return icon
    }

    private var versionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, !shortVersion.isEmpty, !shortVersion.contains("$(") {
            return shortVersion
        }
        if let buildVersion, !buildVersion.isEmpty, !buildVersion.contains("$(") {
            return buildVersion
        }
        return "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: aboutIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            Text("bit11")
                .font(.system(size: 28, weight: .semibold))

            Text(L10n.text("about.tagline"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(L10n.format("about.version", versionText))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(L10n.text("about.license"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.text("about.github_repo"))
                    .font(.subheadline)

                Button {
                    openURL(URL(string: "https://github.com/SigFoundry/bit11")!)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help(L10n.text("about.github_open"))
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 420, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
