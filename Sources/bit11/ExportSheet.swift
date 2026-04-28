import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var isPreparingExport = false
    @State private var isPasswordVisible = false
    @State private var exportErrorMessage: String?
    @State private var showNoEscapeWarning = false
    @State private var isRegisterPasswordSheetPresented = false
    @State private var pendingSavedPasswordDeletion: SavedPassword?
    @State private var isAdvancedSettingsExpanded = false

    private let previewSample = "\u{301C}日本語_鷗＆髙_①_😊.txt"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("export.sheet_title"))
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text(L10n.text("export.password"))
                    HStack(spacing: 8) {
                        PasswordRevealField(
                            title: L10n.text("export.password_placeholder"),
                            text: Binding(
                                get: { workspace.exportOptions.password },
                                set: { newValue in
                                    workspace.exportOptions.password = newValue
                                    workspace.exportOptions.savedPasswordID = nil
                                }
                            ),
                            isVisible: $isPasswordVisible
                        )

                        Menu {
                            ForEach(workspace.savedPasswords) { entry in
                                Button(entry.title) {
                                    workspace.selectSavedPassword(id: entry.id)
                                }
                            }

                            if !workspace.savedPasswords.isEmpty {
                                Divider()
                                Menu(L10n.text("export.password_delete_saved")) {
                                    ForEach(workspace.savedPasswords) { entry in
                                        Button(role: .destructive) {
                                            pendingSavedPasswordDeletion = entry
                                        } label: {
                                            Text(entry.title)
                                        }
                                    }
                                }
                            }

                            if !workspace.savedPasswords.isEmpty {
                                Divider()
                            }

                            Button(L10n.text("export.password_register")) {
                                isRegisterPasswordSheetPresented = true
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .frame(width: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .help(L10n.text("export.password_saved_menu"))
                    }
                }

                GridRow {
                    Text(L10n.text("export.options"))
                    Toggle(L10n.text("export.ignore_empty_folders"), isOn: $workspace.exportOptions.ignoreEmptyFolders)
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isAdvancedSettingsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isAdvancedSettingsExpanded ? "chevron.down" : "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(L10n.text("export.advanced_settings"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isAdvancedSettingsExpanded {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                        GridRow {
                            Text(L10n.text("export.metadata_encoding"))
                            Picker(L10n.text("export.metadata_encoding"), selection: $workspace.exportOptions.filenameEncoding) {
                                ForEach(FilenameEncoding.allCases) { encoding in
                                    Text(encoding.label).tag(encoding)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: workspace.exportOptions.filenameEncoding) { _, newValue in
                                applyEncodingDefaults(for: newValue)
                            }
                        }

                        GridRow {
                            Text(L10n.text("export.escape_mode"))
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(L10n.text("export.escape_mode"), selection: $workspace.exportOptions.escapeMode) {
                                    ForEach(EscapeMode.allCases) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .disabled(workspace.exportOptions.filenameEncoding.locksEscapeMode)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.text("export.escape_preview_title"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(previewSample) -> \(workspace.exportOptions.escapePreview(for: previewSample))")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        GridRow {
                            Text(L10n.text("export.compression"))
                            Picker(L10n.text("export.compression"), selection: $workspace.exportOptions.compression) {
                                ForEach(CompressionPreset.allCases) { preset in
                                    Text(preset.label).tag(preset)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(.top, 10)
                }
            }

            HStack {
                Button(L10n.text("export.zip_style")) {
                    workspace.reopenExportWizardFromExportSheet()
                }
                .disabled(isPreparingExport)

                Spacer()

                Button(L10n.text("common.cancel")) {
                    dismiss()
                }

                Button(isPreparingExport ? L10n.text("export.preparing") : createButtonTitle) {
                    export()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparingExport)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            applyEncodingDefaults(for: workspace.exportOptions.filenameEncoding)
        }
        .alert(
            L10n.text("error.export.title"),
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("common.ok"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert(
            L10n.text("export.no_escape_warning_title"),
            isPresented: $showNoEscapeWarning
        ) {
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("common.continue")) {
                performExport()
            }
        } message: {
            Text(L10n.text("export.no_escape_warning_message"))
        }
        .alert(
            L10n.text("password.delete_confirm_title"),
            isPresented: Binding(
                get: { pendingSavedPasswordDeletion != nil },
                set: { if !$0 { pendingSavedPasswordDeletion = nil } }
            ),
            presenting: pendingSavedPasswordDeletion
        ) { entry in
            Button(L10n.text("common.cancel"), role: .cancel) {
                pendingSavedPasswordDeletion = nil
            }
            Button(L10n.text("delete.confirm_action"), role: .destructive) {
                workspace.removeSavedPassword(id: entry.id)
                pendingSavedPasswordDeletion = nil
            }
        } message: { _ in
            Text(L10n.text("password.delete_confirm_message"))
        }
        .sheet(isPresented: $isRegisterPasswordSheetPresented) {
            RegisterPasswordSheet { title, password in
                workspace.savePassword(title: title, password: password)
            }
        }
    }

    private func export() {
        if workspace.exportOptions.escapeMode == .fixed,
           !workspace.exportOptions.filenameEncoding.locksEscapeMode {
            showNoEscapeWarning = true
            return
        }

        performExport()
    }

    private func performExport() {
        isPreparingExport = true

        do {
            try workspace.exportToUserSelectedLocation { result in
                isPreparingExport = false
                switch result {
                case .success(true):
                    dismiss()
                case .success(false):
                    break
                case .failure(let error):
                    if let localizedError = error as? LocalizedError,
                       let description = localizedError.errorDescription {
                        exportErrorMessage = description
                    } else {
                        exportErrorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            isPreparingExport = false
            if let localizedError = error as? LocalizedError,
               let description = localizedError.errorDescription {
                exportErrorMessage = description
            } else {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyEncodingDefaults(for encoding: FilenameEncoding) {
        if encoding.locksEscapeMode {
            workspace.exportOptions.escapeMode = .fixed
        } else {
            workspace.exportOptions.escapeMode = .bestEffort
        }
    }

    private var createButtonTitle: String {
        if workspace.exportOptions.passwordOrNil != nil {
            return L10n.text("export.create_encrypted_zip")
        }
        return L10n.text("export.create_zip")
    }
}

private struct PasswordRevealField: View {
    let title: String
    @Binding var text: String
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("export.password_toggle_visibility"))
        }
    }
}

private struct RegisterPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isPasswordVisible = false
    @State private var isConfirmPasswordVisible = false

    let onSave: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("export.password_register"))
                .font(.title3.weight(.semibold))

            TextField(L10n.text("export.password_title"), text: $title)

            PasswordRevealField(
                title: L10n.text("export.password_value"),
                text: $password,
                isVisible: $isPasswordVisible
            )

            PasswordRevealField(
                title: L10n.text("export.password_confirm"),
                text: $confirmPassword,
                isVisible: $isConfirmPasswordVisible
            )

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) {
                    dismiss()
                }
                Button(L10n.text("export.password_save")) {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), password)
                    dismiss()
                }
                .disabled(validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("export.password_register_title_required")
        }
        if password.isEmpty {
            return L10n.text("export.password_register_password_required")
        }
        if confirmPassword.isEmpty {
            return L10n.text("export.password_register_confirm_required")
        }
        if password != confirmPassword {
            return L10n.text("export.password_register_mismatch")
        }
        return nil
    }
}
