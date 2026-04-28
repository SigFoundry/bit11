import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ZipExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ZipStructureDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw StructureError.invalidData
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ContentView: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @State private var dropTargetID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                FolderSidebar()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            } detail: {
                VStack(spacing: 0) {
                    ToolbarStrip()
                    Divider()
                    ItemBrowser(dropTargetID: $dropTargetID)
                }
            }
            Divider()
            StatusBar()
        }
        .overlay(alignment: .top) {
            if let toastMessage = workspace.toastMessage {
                ToastBanner(message: toastMessage)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let exportProgress = workspace.exportProgress {
                ZStack {
                    Color.black.opacity(0.10)
                        .ignoresSafeArea()
                    ExportProgressOverlay(progress: exportProgress)
                }
            }
        }
        .sheet(isPresented: $workspace.isExportWizardPresented) {
            ExportWizardSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isExportSheetPresented) {
            ExportSheet()
                .environmentObject(workspace)
        }
        .sheet(item: renameBindingNode) { node in
            RenameSheet(node: node, renameText: $renameText)
                .environmentObject(workspace)
        }
        .fileExporter(
            isPresented: $workspace.isStructureExporterPresented,
            document: workspace.structureDocument,
            contentType: .json,
            defaultFilename: L10n.text("structure.default_filename")
        ) { result in
            workspace.handleStructureExportResult(result)
        }
        .fileImporter(
            isPresented: $workspace.isStructureImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            workspace.handleStructureImportResult(result)
        }
        .alert(L10n.text("error.export.title"), isPresented: Binding(
            get: { workspace.lastErrorMessage != nil },
            set: { if !$0 { workspace.lastErrorMessage = nil } }
        )) {
            Button(L10n.text("common.ok"), role: .cancel) {}
        } message: {
            Text(workspace.lastErrorMessage ?? "")
        }
        .alert(
            L10n.text("delete.confirm_title"),
            isPresented: Binding(
                get: { workspace.pendingDeletion != nil },
                set: { if !$0 { workspace.cancelDeletion() } }
            ),
            presenting: workspace.pendingDeletion
        ) { pendingDeletion in
            Button(L10n.text("common.cancel"), role: .cancel) {
                workspace.cancelDeletion()
            }
            Button(L10n.text("delete.confirm_action"), role: .destructive) {
                workspace.confirmDeletion()
            }
        } message: { pendingDeletion in
            Text(L10n.format("delete.confirm_message", pendingDeletion.count))
        }
        .onChange(of: workspace.renamingNodeID) { _, newValue in
            if let newValue, let node = workspace.findNode(id: newValue) {
                renameText = node.name
            }
        }
        .animation(.easeInOut(duration: 0.25), value: workspace.toastMessage)
        .animation(.easeInOut(duration: 0.2), value: workspace.exportProgress != nil)
    }

    private var renameBindingNode: Binding<ZipNode?> {
        Binding(
            get: {
                guard let id = workspace.renamingNodeID else { return nil }
                return workspace.findNode(id: id)
            },
            set: { newValue in
                if newValue == nil {
                    DispatchQueue.main.async {
                        workspace.cancelRename()
                    }
                }
            }
        )
    }
}

private struct ToolbarStrip: View {
    @EnvironmentObject private var workspace: ZipWorkspace

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.selectedFolder.displayName)
                    .font(.title3.weight(.semibold))
                Text(workspace.selectedFolderArchivePath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                workspace.addFolder()
            } label: {
                Label {
                    Text(L10n.text("action.new_folder"))
                } icon: {
                    Image(systemName: "folder.badge.plus")
                }
            }

            Button {
                workspace.beginExport()
            } label: {
                Label {
                    Text(L10n.text("action.zip"))
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.regularMaterial)
    }
}

private struct ExportWizardSheet: View {
    @EnvironmentObject private var workspace: ZipWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text("wizard.title"))
                .font(.title2.weight(.semibold))

            HStack(spacing: 18) {
                ForEach(ExportStylePreset.allCases) { preset in
                    Button {
                        workspace.exportWizardSelectedPreset = preset
                    } label: {
                        VStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(isSelected(preset) ? 0.18 : 0.08))
                                    .frame(width: 76, height: 76)

                                Image(systemName: preset.symbolName)
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(isSelected(preset) ? Color.accentColor : .primary)
                            }

                            Text(preset.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)

                            Text(preset.caption)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 28)
                                .fill(isSelected(preset) ? Color.accentColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(isSelected(preset) ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isSelected(preset) ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle(L10n.text("wizard.default_toggle"), isOn: $workspace.exportWizardSkipNextTime)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()

                Button(L10n.text("common.cancel")) {
                    workspace.cancelExportWizard()
                }

                Button(L10n.text("wizard.action.export")) {
                    workspace.completeExportWizard()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 760)
    }

    private func isSelected(_ preset: ExportStylePreset) -> Bool {
        workspace.exportWizardSelectedPreset == preset
    }
}

private struct FolderSidebar: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @State private var dropTargetID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                SidebarNodeRow(node: workspace.root, depth: 0, dropTargetID: $dropTargetID)
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SidebarNodeRow: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @ObservedObject var node: ZipNode
    let depth: Int
    @Binding var dropTargetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: node.parent == nil ? "archivebox" : "folder")
                    .frame(width: 16)
                Text(node.displayName)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .focusable()
            .onDrag {
                workspace.selectSingleItem(node.id)
                return NSItemProvider(object: node.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                get: { dropTargetID == node.id },
                set: { isTargeted in
                    dropTargetID = isTargeted ? node.id : nil
                }
            )) { providers in
                handleSidebarDrop(providers: providers)
            }
            .onTapGesture {
                workspace.selectedFolderID = node.id
                workspace.selectSingleItem(node.id)
            }
            .onSubmit {
                workspace.beginRenameSelectedFolder()
            }
            .onKeyPress(.return) {
                guard workspace.selectedFolderID == node.id, node.parent != nil else {
                    return .ignored
                }
                DispatchQueue.main.async {
                    workspace.beginRename(node: node, focusFolder: true)
                }
                return .handled
            }
            .contextMenu {
                if node.parent != nil {
                    Button(L10n.text("action.rename")) {
                        workspace.beginRename(node: node, focusFolder: true)
                    }
                }

                Button(L10n.text("action.new_folder")) {
                    workspace.addFolder(to: node)
                }

                if node.parent != nil {
                    Button(L10n.text("delete.confirm_action"), role: .destructive) {
                        workspace.promptDelete(node: node)
                    }
                }
            }

            ForEach(node.sortedChildren.filter(\.isDirectory)) { child in
                SidebarNodeRow(node: child, depth: depth + 1, dropTargetID: $dropTargetID)
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        if dropTargetID == node.id {
            return Color.accentColor.opacity(0.22)
        }
        if workspace.selectedFolderID == node.id {
            return Color.accentColor.opacity(0.16)
        }
        return .clear
    }

    private func handleSidebarDrop(providers: [NSItemProvider]) -> Bool {
        guard node.isDirectory else { return false }
        let destinationID = node.id

        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let value = object as? NSString,
                      let sourceID = UUID(uuidString: value as String) else { return }

                Task { @MainActor in
                    workspace.moveFolder(id: sourceID, to: destinationID)
                    dropTargetID = nil
                }
            }
            return true
        }

        return false
    }
}

private struct ItemBrowser: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @Binding var dropTargetID: UUID?
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var dragStartPoint: CGPoint?
    @State private var dragCurrentPoint: CGPoint?
    @State private var dragBaseSelection: Set<UUID> = []

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: max(proxy.size.height - 20, 1), alignment: .topLeading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(L10n.text("action.new_folder")) {
                                workspace.addFolder()
                            }
                        }

                    LazyVStack(spacing: 4) {
                        ForEach(workspace.selectedFolder.sortedChildren) { node in
                            ItemRow(node: node, dropTargetID: $dropTargetID)
                                .background(
                                    GeometryReader { rowProxy in
                                        Color.clear.preference(
                                            key: ItemFramePreferenceKey.self,
                                            value: [node.id: rowProxy.frame(in: .named("item-browser"))]
                                        )
                                    }
                                )
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .coordinateSpace(name: "item-browser")
        .focusable()
        .onDeleteCommand {
            workspace.promptDeleteSelection()
        }
        .onKeyPress(.delete) {
            workspace.promptDeleteSelection()
            return .handled
        }
        .onKeyPress(.return) {
            guard workspace.selectedItemIDs.count == 1,
                  let selectedID = workspace.primarySelectedItemID,
                  let node = workspace.findNode(id: selectedID),
                  node.parent?.id == workspace.selectedFolder.id else {
                return .ignored
            }
            DispatchQueue.main.async {
                workspace.beginRename(node: node)
            }
            return .handled
        }
        .overlay {
            if workspace.selectedFolder.children.isEmpty {
                ContentUnavailableView(
                    "empty.title",
                    systemImage: "shippingbox",
                    description: Text(L10n.text("empty.description"))
                )
            }
        }
        .overlay(selectionRectangleOverlay)
        .onPreferenceChange(ItemFramePreferenceKey.self) { itemFrames = $0 }
        .gesture(selectionDragGesture)
        .simultaneousGesture(backgroundTapGesture)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers, into: workspace.selectedFolder)
        }
    }

    private func handleDrop(providers: [NSItemProvider], into folder: ZipNode) -> Bool {
        var didAccept = false
        let folderID = folder.id

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didAccept = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    let targetFolder = workspace.findNode(id: folderID) ?? workspace.selectedFolder
                    workspace.importItems(from: [url], into: targetFolder)
                }
            }
        }

        return didAccept
    }

    private var selectionRectangleOverlay: some View {
        Group {
            if let rect = selectionRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("item-browser"))
            .onChanged { value in
                if dragStartPoint == nil {
                    dragStartPoint = value.startLocation
                    dragBaseSelection = workspace.selectedItemIDs
                }

                dragCurrentPoint = value.location
                applyRectangleSelection()
            }
            .onEnded { _ in
                dragStartPoint = nil
                dragCurrentPoint = nil
                dragBaseSelection = []
            }
    }

    private var backgroundTapGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("item-browser"))
            .onEnded { value in
                let dx = value.location.x - value.startLocation.x
                let dy = value.location.y - value.startLocation.y
                let movedTooFar = hypot(dx, dy) > 4
                guard !movedTooFar,
                      !isPointInsideItem(value.startLocation) else { return }
                workspace.selectItems([])
                workspace.setSelectionAnchor(nil)
            }
    }

    private var selectionRect: CGRect? {
        guard let start = dragStartPoint, let current = dragCurrentPoint else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func applyRectangleSelection() {
        guard let rect = selectionRect else { return }
        let intersecting = Set(itemFrames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })
        workspace.selectItems(intersecting)
        if let first = workspace.selectedFolder.sortedChildren.first(where: { intersecting.contains($0.id) }) {
            workspace.setSelectionAnchor(first.id)
        }
    }

    private func isPointInsideItem(_ point: CGPoint) -> Bool {
        itemFrames.values.contains { $0.contains(point) }
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @ObservedObject var node: ZipNode
    @Binding var dropTargetID: UUID?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.isDirectory ? .yellow : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                Text(node.isDirectory ? L10n.format("item.count", node.children.count) : (node.sourceURL?.path(percentEncoded: false) ?? L10n.text("item.imported_file")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            let orderedIDs = workspace.selectedFolder.sortedChildren.map(\.id)
            if modifiers.contains(.shift),
               let anchor = workspace.selectionAnchorID,
               let anchorIndex = orderedIDs.firstIndex(of: anchor),
               let currentIndex = orderedIDs.firstIndex(of: node.id) {
                let range = anchorIndex <= currentIndex ? anchorIndex...currentIndex : currentIndex...anchorIndex
                workspace.selectItems(Set(range.map { orderedIDs[$0] }))
            } else if modifiers.contains(.command) {
                var next = workspace.selectedItemIDs
                if next.contains(node.id) {
                    next.remove(node.id)
                } else {
                    next.insert(node.id)
                }
                workspace.selectItems(next)
                workspace.setSelectionAnchor(node.id)
            } else {
                workspace.selectSingleItem(node.id)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard node.isDirectory else { return }
                workspace.openFolder(node.id)
            }
        )
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { dropTargetID == node.id },
            set: { isTargeted in
                dropTargetID = isTargeted ? node.id : nil
            }
        )) { providers in
            let destination = node.isDirectory ? node : (node.parent ?? workspace.selectedFolder)
            return handleDrop(providers: providers, into: destination)
        }
        .overlay {
            RowContextMenuOverlay(
                menuItems: contextMenuItems,
                onOpen: {
                    if !workspace.selectedItemIDs.contains(node.id) {
                        workspace.selectSingleItem(node.id)
                    }
                }
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider], into folder: ZipNode) -> Bool {
        var didAccept = false
        let folderID = folder.id

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didAccept = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    let targetFolder = workspace.findNode(id: folderID) ?? workspace.selectedFolder
                    workspace.importItems(from: [url], into: targetFolder)
                }
            }
        }

        return didAccept
    }

    private var backgroundColor: Color {
        if dropTargetID == node.id {
            return Color.accentColor.opacity(0.14)
        }
        if workspace.selectedItemIDs.contains(node.id) {
            return Color.accentColor.opacity(0.18)
        }
        return .clear
    }

    private var contextMenuItems: [MenuItemDescriptor] {
        if workspace.selectedItemIDs.count > 1, workspace.selectedItemIDs.contains(node.id) {
            return [
                MenuItemDescriptor(title: L10n.text("action.delete_selection"), isDestructive: true) {
                    workspace.promptDeleteSelection()
                }
            ]
        }

        var items: [MenuItemDescriptor] = [
            MenuItemDescriptor(title: L10n.text("action.rename")) {
                if !workspace.selectedItemIDs.contains(node.id) {
                    workspace.selectSingleItem(node.id)
                }
                workspace.beginRename(node: node)
            }
        ]

        if node.isDirectory {
            items.append(MenuItemDescriptor(title: L10n.text("action.open_folder")) {
                if !workspace.selectedItemIDs.contains(node.id) {
                    workspace.selectSingleItem(node.id)
                }
                workspace.openFolder(node.id)
            })
            items.append(MenuItemDescriptor(title: L10n.text("action.new_folder_inside")) {
                if !workspace.selectedItemIDs.contains(node.id) {
                    workspace.selectSingleItem(node.id)
                }
                workspace.addFolder(to: node)
            })
        }

        items.append(MenuItemDescriptor(title: L10n.text("action.delete"), isDestructive: true) {
            if !workspace.selectedItemIDs.contains(node.id) {
                workspace.selectSingleItem(node.id)
            }
            workspace.promptDelete(node: node)
        })

        return items
    }
}

private struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct RenameSheet: View {
    @EnvironmentObject private var workspace: ZipWorkspace
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var node: ZipNode
    @Binding var renameText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(workspace.renameDialogTitleKey))
                .font(.title3.weight(.semibold))
            TextField(L10n.text("rename.placeholder"), text: $renameText)
                .onSubmit(commitRename)
            if let renameValidationMessage {
                Text(renameValidationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) {
                    workspace.cancelRename()
                    dismiss()
                }
                Button(L10n.text("common.save")) {
                    commitRename()
                }
                .disabled(renameValidationMessage != nil || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitRename() {
        guard renameValidationMessage == nil,
              !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let nodeID = node.id
        let latestText = renameText
        dismiss()
        DispatchQueue.main.async {
            workspace.renameNode(id: nodeID, to: latestText)
        }
    }

    private var renameValidationMessage: String? {
        let currentName = renameText
        if let invalidNameMessage = currentName.archiveNameValidationMessage {
            return invalidNameMessage
        }

        let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parent = node.parent else { return nil }
        if workspace.hasNameConflict(trimmed, in: parent, excluding: node.id) {
            return L10n.text("rename.duplicate_name")
        }

        return nil
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var workspace: ZipWorkspace

    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            Label(L10n.format("status.folders", workspace.totalFolderCount), systemImage: "folder")
            Label(L10n.format("status.files", workspace.totalFileCount), systemImage: "doc")
            Label(L10n.format("status.bytes", ByteCountFormatter.string(fromByteCount: workspace.totalUncompressedBytes, countStyle: .file)), systemImage: "externaldrive")
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

private struct ExportProgressOverlay: View {
    let progress: ExportProgressState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("export.progress_title"))
                .font(.title3.weight(.semibold))

            if let fractionCompleted = progress.fractionCompleted {
                ProgressView(value: fractionCompleted)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(progress.summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let currentItemText = progress.currentItemText {
                Text(currentItemText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }
}

private struct ToastBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }
}

private struct MenuItemDescriptor {
    let title: String
    var isDestructive = false
    let action: () -> Void
}

private struct RowContextMenuOverlay: NSViewRepresentable {
    let menuItems: [MenuItemDescriptor]
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RowContextMenuNSView {
        let view = RowContextMenuNSView()
        view.coordinator = context.coordinator
        view.menuItems = menuItems
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ nsView: RowContextMenuNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.menuItems = menuItems
        nsView.onOpen = onOpen
    }

    final class Coordinator: NSObject {
        private var handlers: [UUID: () -> Void] = [:]

        func makeMenu(from items: [MenuItemDescriptor]) -> NSMenu {
            handlers.removeAll()
            let menu = NSMenu()
            for descriptor in items {
                let item = NSMenuItem(title: descriptor.title, action: #selector(performAction(_:)), keyEquivalent: "")
                let id = UUID()
                handlers[id] = descriptor.action
                item.target = self
                item.representedObject = id
                if descriptor.isDestructive {
                    item.attributedTitle = NSAttributedString(
                        string: descriptor.title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                menu.addItem(item)
            }
            return menu
        }

        @objc func performAction(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID,
                  let handler = handlers[id] else { return }
            handler()
        }
    }
}

private final class RowContextMenuNSView: NSView {
    weak var coordinator: RowContextMenuOverlay.Coordinator?
    var menuItems: [MenuItemDescriptor] = []
    var onOpen: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        presentMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentMenu(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func presentMenu(with event: NSEvent) {
        guard let coordinator else { return }
        let eventCopy = event.copy() as? NSEvent ?? event
        let menuItems = menuItems
        let onOpen = onOpen

        DispatchQueue.main.async { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            onOpen?()
            let menu = coordinator.makeMenu(from: menuItems)
            guard !menu.items.isEmpty else { return }
            NSMenu.popUpContextMenu(menu, with: eventCopy, for: self)
        }
    }
}

private extension String {
    var invalidArchiveFilenameCharacters: [String] {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var results: [String] = []

        for scalar in unicodeScalars {
            if forbidden.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                let value = String(scalar)
                if !results.contains(value) {
                    results.append(value)
                }
            }
        }

        return results
    }

    var archiveNameValidationMessage: String? {
        let invalidCharacters = invalidArchiveFilenameCharacters
        if !invalidCharacters.isEmpty {
            return L10n.format("rename.invalid_characters", invalidCharacters.joined(separator: " "))
        }

        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if trimmed == "." || trimmed == ".." {
            return L10n.text("rename.invalid_reserved_name")
        }

        if trimmed.hasSuffix(".") || trimmed.hasSuffix(" ") {
            return L10n.text("rename.invalid_reserved_name")
        }

        let reservedWindowsNames: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]

        let baseName = (trimmed as NSString).deletingPathExtension.uppercased()
        if reservedWindowsNames.contains(baseName) {
            return L10n.text("rename.invalid_reserved_name")
        }

        return nil
    }
}
