import SwiftUI

struct ZipCommands: Commands {
    @ObservedObject var workspace: ZipWorkspace
    @ObservedObject var localizationSettings: AppLocalizationSettings

    var body: some Commands {
        let _ = localizationSettings.refreshID
        CommandMenu(L10n.text("menu.archive")) {
            Button(L10n.text("action.new_folder")) {
                workspace.addFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(L10n.text("action.open_structure")) {
                workspace.beginStructureImport()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button(L10n.text("action.save_structure")) {
                workspace.beginStructureExport()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button(L10n.text("action.select_all")) {
                workspace.selectAllInSelectedFolder()
            }
            .keyboardShortcut("a", modifiers: [.command])

            Button(L10n.text("action.delete_selection")) {
                workspace.promptDeleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])

            Divider()

            Button(L10n.text("action.export_ellipsis")) {
                workspace.beginExport()
            }
            .keyboardShortcut("e", modifiers: [.command])
        }
    }
}
