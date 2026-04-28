import AppKit
import Foundation
import SwiftUI

enum NodeKind: String, Codable {
    case folder
    case file
}

struct SavedPassword: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var password: String

    init(id: UUID = UUID(), title: String, password: String) {
        self.id = id
        self.title = title
        self.password = password
    }
}

struct PersistedZipNode: Codable {
    var name: String
    var kind: NodeKind
    var sourcePath: String?
    var children: [PersistedZipNode]

    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case sourcePath
        case sourceURL
        case children
    }

    init(node: ZipNode) {
        name = node.name
        kind = node.kind
        sourcePath = node.sourceURL?.path(percentEncoded: false)
        children = node.children.map(PersistedZipNode.init(node:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
            ?? container.decodeIfPresent(String.self, forKey: .sourceURL)
        children = try container.decodeIfPresent([PersistedZipNode].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try container.encode(children, forKey: .children)
    }

    func makeNode() -> ZipNode {
        let node = ZipNode(
            name: name,
            kind: kind,
            sourceURL: sourcePath.map(URL.init(fileURLWithPath:)),
            children: children.map { $0.makeNode() }
        )
        return node
    }
}

struct PersistedExportOptions: Codable {
    var filenameEncoding: FilenameEncoding
    var escapeMode: EscapeMode
    var compression: CompressionPreset
    var ignoreEmptyFolders: Bool

    private enum CodingKeys: String, CodingKey {
        case filenameEncoding
        case escapeMode
        case compression
        case ignoreEmptyFolders
    }

    init(options: ExportOptions) {
        filenameEncoding = options.filenameEncoding
        escapeMode = options.escapeMode
        compression = options.compression
        ignoreEmptyFolders = options.ignoreEmptyFolders
    }

    init(
        filenameEncoding: FilenameEncoding = .legacyJPCP932,
        escapeMode: EscapeMode = .bestEffort,
        compression: CompressionPreset = .balanced,
        ignoreEmptyFolders: Bool = false
    ) {
        self.filenameEncoding = filenameEncoding
        self.escapeMode = escapeMode
        self.compression = compression
        self.ignoreEmptyFolders = ignoreEmptyFolders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filenameEncoding = try container.decodeIfPresent(FilenameEncoding.self, forKey: .filenameEncoding) ?? .legacyJPCP932
        escapeMode = try container.decodeIfPresent(EscapeMode.self, forKey: .escapeMode) ?? .bestEffort
        compression = try container.decodeIfPresent(CompressionPreset.self, forKey: .compression) ?? .balanced
        ignoreEmptyFolders = try container.decodeIfPresent(Bool.self, forKey: .ignoreEmptyFolders) ?? false
    }
}

struct ZipStructureSnapshot: Codable {
    var version = 1
    var exportOptions: PersistedExportOptions
    var rootChildren: [PersistedZipNode]

    private enum CodingKeys: String, CodingKey {
        case version
        case exportOptions
        case rootChildren
        case children
    }

    init(version: Int = 1, exportOptions: PersistedExportOptions, rootChildren: [PersistedZipNode]) {
        self.version = version
        self.exportOptions = exportOptions
        self.rootChildren = rootChildren
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportOptions = try container.decodeIfPresent(PersistedExportOptions.self, forKey: .exportOptions) ?? PersistedExportOptions()
        rootChildren = try container.decodeIfPresent([PersistedZipNode].self, forKey: .rootChildren)
            ?? container.decodeIfPresent([PersistedZipNode].self, forKey: .children)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(exportOptions, forKey: .exportOptions)
        try container.encode(rootChildren, forKey: .rootChildren)
    }
}

struct ExportProgressState {
    let fractionCompleted: Double?
    let summaryText: String
    let currentItemText: String?

    init(plan: ExportProgressPlan) {
        if plan.totalUncompressedBytes > 0 {
            summaryText = L10n.format(
                "export.progress_summary_bytes",
                ByteCountFormatter.string(fromByteCount: 0, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(plan.totalUncompressedBytes), countStyle: .file)
            )
        } else {
            summaryText = L10n.format("export.progress_summary_entries", 0, plan.totalEntries)
        }
        fractionCompleted = plan.totalEntries > 0 || plan.totalUncompressedBytes > 0 ? 0 : nil
        currentItemText = nil
    }

    init(snapshot: ExportProgressSnapshot) {
        if snapshot.totalUncompressedBytes > 0 {
            summaryText = L10n.format(
                "export.progress_summary_bytes",
                ByteCountFormatter.string(fromByteCount: Int64(snapshot.completedUncompressedBytes), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(snapshot.totalUncompressedBytes), countStyle: .file)
            )
        } else {
            summaryText = L10n.format("export.progress_summary_entries", snapshot.completedEntries, snapshot.totalEntries)
        }
        fractionCompleted = snapshot.fractionCompleted
        if snapshot.currentPath.isEmpty {
            currentItemText = nil
        } else {
            currentItemText = L10n.format("export.progress_current_item", snapshot.currentPath)
        }
    }
}

struct PendingDeletion: Identifiable {
    let id = UUID()
    let nodeIDs: [UUID]

    var count: Int { nodeIDs.count }
}

final class ZipNode: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    let kind: NodeKind
    let sourceURL: URL?
    @Published var children: [ZipNode]
    weak var parent: ZipNode?

    init(
        id: UUID = UUID(),
        name: String,
        kind: NodeKind,
        sourceURL: URL? = nil,
        children: [ZipNode] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceURL = sourceURL
        self.children = children

        for child in children {
            child.parent = self
        }
    }

    var isDirectory: Bool { kind == .folder }

    var displayName: String {
        if parent == nil {
            return L10n.text("sidebar.archive_root")
        }
        return name
    }

    var archivePath: String {
        guard let parent else { return "/" }
        if parent.parent == nil {
            return "/\(name)"
        }
        return "\(parent.archivePath)/\(name)"
    }

    var sortedChildren: [ZipNode] {
        children.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var folderChildren: [ZipNode]? {
        let folders = sortedChildren.filter(\.isDirectory)
        return folders.isEmpty ? nil : folders
    }

    var totalFolderCount: Int {
        let ownCount = parent == nil ? 0 : (isDirectory ? 1 : 0)
        return ownCount + children.reduce(0) { $0 + $1.totalFolderCount }
    }

    var totalFileCount: Int {
        let ownCount = isDirectory ? 0 : 1
        return ownCount + children.reduce(0) { $0 + $1.totalFileCount }
    }

    var totalUncompressedBytes: Int64 {
        let ownBytes: Int64
        if isDirectory {
            ownBytes = 0
        } else if let sourceURL,
                  let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize {
            ownBytes = Int64(size)
        } else {
            ownBytes = 0
        }

        return ownBytes + children.reduce(0) { $0 + $1.totalUncompressedBytes }
    }

    func addChild(_ child: ZipNode) {
        child.parent = self
        children.append(child)
        objectWillChange.send()
    }

    func removeChild(id: UUID) {
        children.removeAll { $0.id == id }
        objectWillChange.send()
    }

    func containsDescendant(id: UUID) -> Bool {
        if self.id == id { return true }
        return children.contains(where: { $0.containsDescendant(id: id) })
    }

    func detachedCopy() -> ZipNode {
        ZipNode(
            id: id,
            name: name,
            kind: kind,
            sourceURL: sourceURL,
            children: children.map { $0.detachedCopy() }
        )
    }
}

enum FilenameEncoding: String, CaseIterable, Identifiable, Codable {
    case standardUTF8
    case standardUTF8NoExtra
    case legacyJPCP932
    case legacyJPCP932NoExtra
    case legacyUTF16LE
    case legacyEUCJP

    var id: String { rawValue }

    var locksEscapeMode: Bool {
        switch self {
        case .standardUTF8, .standardUTF8NoExtra:
            true
        case .legacyJPCP932, .legacyJPCP932NoExtra, .legacyUTF16LE, .legacyEUCJP:
            false
        }
    }

    var label: String {
        switch self {
        case .standardUTF8: L10n.text("encoding.standard_utf8")
        case .standardUTF8NoExtra: L10n.text("encoding.standard_utf8_no_extra")
        case .legacyJPCP932: L10n.text("encoding.legacy_jp_cp932")
        case .legacyJPCP932NoExtra: L10n.text("encoding.legacy_jp_cp932_no_extra")
        case .legacyUTF16LE: L10n.text("encoding.legacy_utf16le")
        case .legacyEUCJP: L10n.text("encoding.legacy_eucjp")
        }
    }
}

enum EscapeMode: String, CaseIterable, Identifiable, Codable {
    case fixed
    case unicodeCodepoint
    case bestEffort

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fixed: L10n.text("escape.fixed")
        case .unicodeCodepoint: L10n.text("escape.unicode_codepoint")
        case .bestEffort: L10n.text("escape.best_effort")
        }
    }
}

enum CompressionPreset: String, CaseIterable, Identifiable, Codable {
    case none
    case fast
    case balanced
    case maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: L10n.text("compression.store")
        case .fast: L10n.text("compression.fast")
        case .balanced: L10n.text("compression.balanced")
        case .maximum: L10n.text("compression.maximum")
        }
    }
}

enum ExportStylePreset: String, CaseIterable, Identifiable, Codable {
    case macOSModernLinux
    case windows1011
    case legacyJapaneseWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOSModernLinux: L10n.text("wizard.style.modern_mac")
        case .windows1011: L10n.text("wizard.style.windows_modern")
        case .legacyJapaneseWindows: L10n.text("wizard.style.legacy_jp")
        }
    }

    var caption: String {
        switch self {
        case .macOSModernLinux: L10n.text("wizard.style.modern_mac.caption")
        case .windows1011: L10n.text("wizard.style.windows_modern.caption")
        case .legacyJapaneseWindows: L10n.text("wizard.style.legacy_jp.caption")
        }
    }

    var symbolName: String {
        switch self {
        case .macOSModernLinux: "laptopcomputer"
        case .windows1011: "desktopcomputer"
        case .legacyJapaneseWindows: "pc"
        }
    }

    var filenameEncoding: FilenameEncoding {
        switch self {
        case .macOSModernLinux: .standardUTF8
        case .windows1011: .standardUTF8
        case .legacyJapaneseWindows: .legacyJPCP932
        }
    }
}

struct ExportOptions {
    var filenameEncoding: FilenameEncoding = .legacyJPCP932
    var escapeMode: EscapeMode = .bestEffort
    var password: String = ""
    var savedPasswordID: UUID?
    var compression: CompressionPreset = .balanced
    var ignoreEmptyFolders = false

    var passwordOrNil: String? {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func escapePreview(for sample: String) -> String {
        switch filenameEncoding {
        case .standardUTF8, .standardUTF8NoExtra, .legacyUTF16LE:
            return sample
        case .legacyJPCP932, .legacyJPCP932NoExtra:
            return transformedPreview(sample: sample, encoding: .cp932)
        case .legacyEUCJP:
            return transformedPreview(sample: sample, encoding: .eucJP)
        }
    }

    private func transformedPreview(sample: String, encoding: String.Encoding) -> String {
        sample.unicodeScalars.map { scalar in
            let char = String(scalar)
            if char.data(using: encoding) != nil {
                return char
            }

            switch escapeMode {
            case .fixed:
                return char
            case .unicodeCodepoint:
                return "U+\(String(format: "%04X", scalar.value))"
            case .bestEffort:
                if let replacement = bestEffortReplacement(for: scalar),
                   replacement.data(using: encoding) != nil {
                    return replacement
                }
                return "U+\(String(format: "%04X", scalar.value))"
            }
        }.joined()
    }

    private func bestEffortReplacement(for scalar: UnicodeScalar) -> String? {
        switch scalar.value {
        case 0x9AD9:
            "高"
        default:
            nil
        }
    }
}

enum ExportError: LocalizedError {
    case noContent
    case fileReadFailed(URL)
    case cannotEncodeFilename(String)
    case compressionFailed(String)
    case zip64RequiredForEntry(String)
    case zip64RequiredForArchive
    case tooManyEntries

    var errorDescription: String? {
        switch self {
        case .noContent:
            return L10n.text("error.no_content")
        case .fileReadFailed(let url):
            return L10n.format("error.file_read_failed", url.lastPathComponent)
        case .cannotEncodeFilename(let path):
            return L10n.format("error.cannot_encode_filename", path)
        case .compressionFailed(let path):
            return L10n.format("error.compression_failed", path)
        case .zip64RequiredForEntry(let path):
            return L10n.format("error.zip64_entry_too_large", path)
        case .zip64RequiredForArchive:
            return L10n.text("error.zip64_archive_too_large")
        case .tooManyEntries:
            return L10n.text("error.zip64_too_many_entries")
        }
    }
}

enum StructureError: LocalizedError {
    case invalidData
    case failedToRead(URL)
    case failedToWrite

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return L10n.text("error.structure_invalid")
        case .failedToRead(let url):
            return L10n.format("error.structure_read_failed", url.lastPathComponent)
        case .failedToWrite:
            return L10n.text("error.structure_write_failed")
        }
    }
}

private final class WeakZipWorkspaceBox: @unchecked Sendable {
    weak var workspace: ZipWorkspace?

    init(_ workspace: ZipWorkspace) {
        self.workspace = workspace
    }
}

@MainActor
final class ZipWorkspace: ObservableObject {
    private enum StorageKeys {
        static let savedPasswords = "savedPasswords"
        static let exportWizardDefaultPreset = "exportWizardDefaultPreset"
        static let exportWizardSkipsPrompt = "exportWizardSkipsPrompt"
    }

    @Published var root = ZipNode(name: "", kind: .folder)
    @Published var selectedFolderID: UUID?
    @Published var selectedItemIDs: Set<UUID> = []
    @Published var exportOptions = ExportOptions()
    @Published var savedPasswords: [SavedPassword] = [] {
        didSet { persistSavedPasswords() }
    }
    @Published var isExportWizardPresented = false
    @Published var exportWizardSelectedPreset: ExportStylePreset = .macOSModernLinux
    @Published var exportWizardSkipNextTime = false
    @Published var isExportSheetPresented = false
    @Published var isStructureExporterPresented = false
    @Published var isStructureImporterPresented = false
    @Published var structureDocument: ZipStructureDocument?
    @Published var renamingNodeID: UUID?
    @Published var renameDialogTitleKey = "rename.title"
    @Published var pendingDeletion: PendingDeletion?
    @Published var lastErrorMessage: String?
    @Published var toastMessage: String?
    @Published var exportProgress: ExportProgressState?
    private var toastTask: Task<Void, Never>?
    private(set) var selectionAnchorID: UUID?

    init() {
        selectedFolderID = root.id
        savedPasswords = loadSavedPasswords()
        let wizardPreference = loadExportWizardPreference()
        exportWizardSelectedPreset = wizardPreference.preset ?? .macOSModernLinux
        exportWizardSkipNextTime = wizardPreference.skip
    }

    var selectedFolder: ZipNode {
        findNode(id: selectedFolderID ?? root.id) ?? root
    }

    var primarySelectedItemID: UUID? {
        selectedItemIDs.first
    }

    var totalFolderCount: Int { root.totalFolderCount }
    var totalFileCount: Int { root.totalFileCount }
    var totalUncompressedBytes: Int64 { root.totalUncompressedBytes }
    var selectedFolderArchivePath: String { selectedFolder.archivePath }

    private func clearRenameState() {
        renameDialogTitleKey = "rename.title"
        renamingNodeID = nil
    }

    private func presentRenameDialog(for nodeID: UUID, titleKey: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renameDialogTitleKey = titleKey
            self.renamingNodeID = nodeID
        }
    }

    func findNode(id: UUID) -> ZipNode? {
        findNode(id: id, in: root)
    }

    private func findNode(id: UUID, in node: ZipNode) -> ZipNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    func addFolder(
        named proposedName: String = L10n.text("action.new_folder"),
        to folder: ZipNode? = nil,
        beginRenaming: Bool = true
    ) {
        let target = folder ?? selectedFolder
        let newName = uniqueName(for: proposedName, in: target)
        let newFolder = ZipNode(name: newName, kind: .folder)
        target.addChild(newFolder)
        selectedFolderID = target.id
        selectedItemIDs = [newFolder.id]
        if beginRenaming {
            presentRenameDialog(for: newFolder.id, titleKey: "rename.title.new_folder")
        } else {
            clearRenameState()
        }
        objectWillChange.send()
    }

    func beginRename(node: ZipNode, focusFolder: Bool = false) {
        selectedItemIDs = [node.id]
        if focusFolder, node.isDirectory {
            selectedFolderID = node.id
        }
        presentRenameDialog(for: node.id, titleKey: "rename.title")
    }

    func beginRenameSelectedFolder() {
        guard let folder = findNode(id: selectedFolderID ?? root.id),
              folder.parent != nil else { return }
        beginRename(node: folder, focusFolder: true)
    }

    func renameNode(id: UUID, to proposedName: String) {
        guard let node = findNode(id: id),
              node.id != root.id,
              let parent = node.parent else {
            clearRenameState()
            return
        }

        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearRenameState()
            return
        }

        guard !hasNameConflict(trimmed, in: parent, excluding: id) else {
            lastErrorMessage = L10n.text("error.duplicate_name")
            return
        }

        node.name = trimmed
        clearRenameState()
        objectWillChange.send()
    }

    func cancelRename() {
        clearRenameState()
    }

    func selectItems(_ ids: Set<UUID>) {
        selectedItemIDs = ids
    }

    func selectSingleItem(_ id: UUID) {
        selectedItemIDs = [id]
        selectionAnchorID = id
    }

    func setSelectionAnchor(_ id: UUID?) {
        selectionAnchorID = id
    }

    func openFolder(_ id: UUID) {
        guard let node = findNode(id: id), node.isDirectory else { return }
        selectedFolderID = id
        selectedItemIDs = [id]
    }

    func moveFolder(id: UUID, to destinationID: UUID) {
        guard let node = findNode(id: id),
              let destination = findNode(id: destinationID),
              node.isDirectory,
              destination.isDirectory,
              node.id != root.id,
              node.id != destination.id,
              !node.containsDescendant(id: destination.id),
              let sourceParent = node.parent,
              sourceParent.id != destination.id else { return }

        guard !hasNameConflict(node.name, in: destination, excluding: node.id) else {
            lastErrorMessage = L10n.text("error.duplicate_name")
            return
        }

        sourceParent.removeChild(id: node.id)
        destination.addChild(node)
        selectedFolderID = destination.id
        selectedItemIDs = [node.id]
        objectWillChange.send()
    }

    func selectAllInSelectedFolder() {
        selectedItemIDs = Set(selectedFolder.children.map(\.id))
    }

    func promptDeleteSelection() {
        let nodeIDs = normalizedDeletionIDs(from: Array(selectedItemIDs))
        guard !nodeIDs.isEmpty else { return }
        pendingDeletion = PendingDeletion(nodeIDs: nodeIDs)
    }

    func promptDelete(node: ZipNode) {
        if selectedItemIDs.contains(node.id) {
            promptDeleteSelection()
            return
        }

        selectedItemIDs = [node.id]
        if node.isDirectory {
            selectedFolderID = node.id
        }
        pendingDeletion = PendingDeletion(nodeIDs: normalizedDeletionIDs(from: [node.id]))
    }

    func confirmDeletion() {
        guard let pendingDeletion else { return }

        for id in pendingDeletion.nodeIDs {
            guard id != root.id,
                  let node = findNode(id: id),
                  let parent = node.parent else { continue }

            parent.removeChild(id: id)
            if selectedFolderID == id {
                selectedFolderID = parent.id
            }
        }

        selectedItemIDs.removeAll()
        self.pendingDeletion = nil
        objectWillChange.send()
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    func showToast(_ message: String, duration: UInt64 = 3_000_000_000) {
        toastTask?.cancel()
        toastMessage = message

        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self?.toastMessage = nil
            }
        }
    }

    func importItems(from urls: [URL], into folder: ZipNode? = nil) {
        let target = folder ?? selectedFolder

        for url in urls {
            if let node = makeNode(from: url, siblingNames: Set(target.children.map(\.name))) {
                target.addChild(node)
            }
        }

        objectWillChange.send()
    }

    private func makeNode(from url: URL, siblingNames: Set<String>) -> ZipNode? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory ?? false
        let unique = uniqueName(for: url.lastPathComponent, siblingNames: siblingNames)

        if isDirectory {
            let folder = ZipNode(name: unique, kind: .folder)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for childURL in children {
                if let child = makeNode(from: childURL, siblingNames: Set(folder.children.map(\.name))) {
                    folder.addChild(child)
                }
            }
            return folder
        } else {
            return ZipNode(name: unique, kind: .file, sourceURL: url)
        }
    }

    func beginExport() {
        let wizardPreference = loadExportWizardPreference()
        if wizardPreference.skip, let preset = wizardPreference.preset {
            applyExportStylePreset(preset)
            isExportSheetPresented = true
            return
        }

        exportWizardSelectedPreset = wizardPreference.preset ?? inferredExportStylePreset()
        exportWizardSkipNextTime = false
        isExportWizardPresented = true
    }

    func cancelExportWizard() {
        isExportWizardPresented = false
    }

    func reopenExportWizardFromExportSheet() {
        isExportSheetPresented = false
        exportWizardSelectedPreset = inferredExportStylePreset()
        DispatchQueue.main.async { [weak self] in
            self?.isExportWizardPresented = true
        }
    }

    func completeExportWizard() {
        let preset = exportWizardSelectedPreset
        applyExportStylePreset(preset)
        persistExportWizardPreference(preset: preset, skip: exportWizardSkipNextTime)
        isExportWizardPresented = false
        DispatchQueue.main.async { [weak self] in
            self?.isExportSheetPresented = true
        }
    }

    func beginStructureImport() {
        isStructureImporterPresented = true
    }

    func beginStructureExport() {
        do {
            structureDocument = try ZipStructureDocument(data: makeStructureData())
            isStructureExporterPresented = true
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func exportToUserSelectedLocation(completion: @escaping (Result<Bool, Error>) -> Void) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(L10n.text("export.default_filename")).zip"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard let self else {
                completion(.success(false))
                return
            }
            guard response == .OK, let url = panel.url else {
                completion(.success(false))
                return
            }

            do {
                let exportRoot = self.root.detachedCopy()
                let writer = try ZipArchiveWriter(root: exportRoot, options: self.exportOptions)
                let plan = try writer.makeProgressPlan()
                self.exportProgress = ExportProgressState(plan: plan)
                completion(.success(true))
                self.startExport(writer: writer, destination: url)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func startExport(writer: ZipArchiveWriter, destination: URL) {
        let workspaceBox = WeakZipWorkspaceBox(self)
        Thread.detachNewThread {
            autoreleasepool {
                do {
                    try writer.write(to: destination) { snapshot in
                        DispatchQueue.main.async {
                            workspaceBox.workspace?.exportProgress = ExportProgressState(snapshot: snapshot)
                        }
                    }
                    DispatchQueue.main.async {
                        workspaceBox.workspace?.exportProgress = nil
                        workspaceBox.workspace?.showToast(L10n.text("export.success_toast"))
                    }
                } catch let error as LocalizedError {
                    DispatchQueue.main.async {
                        workspaceBox.workspace?.exportProgress = nil
                        workspaceBox.workspace?.lastErrorMessage = error.errorDescription ?? error.localizedDescription
                    }
                } catch {
                    DispatchQueue.main.async {
                        workspaceBox.workspace?.exportProgress = nil
                        workspaceBox.workspace?.lastErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func handleStructureExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            lastErrorMessage = error.localizedDescription
        }

        structureDocument = nil
    }

    func handleStructureImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            do {
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: url)
                try loadStructureData(data)
            } catch let error as LocalizedError {
                lastErrorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                lastErrorMessage = StructureError.failedToRead(url).localizedDescription
            }
        case .failure(let error):
            lastErrorMessage = error.localizedDescription
        }
    }

    func performExport(to destination: URL) throws {
        let writer = try ZipArchiveWriter(root: root.detachedCopy(), options: exportOptions)
        try writer.write(to: destination)
    }

    func makeExportData() throws -> Data {
        let writer = try ZipArchiveWriter(root: root.detachedCopy(), options: exportOptions)
        return try writer.makeArchiveData()
    }

    func makeStructureData() throws -> Data {
        let snapshot = ZipStructureSnapshot(
            exportOptions: PersistedExportOptions(options: exportOptions),
            rootChildren: root.children.map(PersistedZipNode.init(node:))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    func loadStructureData(_ data: Data) throws {
        let decoder = JSONDecoder()
        let snapshot: ZipStructureSnapshot

        do {
            snapshot = try decoder.decode(ZipStructureSnapshot.self, from: data)
        } catch {
            throw StructureError.invalidData
        }

        let newRoot = ZipNode(name: "", kind: .folder, children: snapshot.rootChildren.map { $0.makeNode() })
        root = newRoot
        exportOptions.filenameEncoding = snapshot.exportOptions.filenameEncoding
        exportOptions.escapeMode = snapshot.exportOptions.escapeMode
        exportOptions.compression = snapshot.exportOptions.compression
        exportOptions.ignoreEmptyFolders = snapshot.exportOptions.ignoreEmptyFolders
        exportOptions.password = ""
        exportOptions.savedPasswordID = nil
        selectedFolderID = newRoot.id
        selectedItemIDs.removeAll()
        renamingNodeID = nil
        objectWillChange.send()
    }

    private func applyExportStylePreset(_ preset: ExportStylePreset) {
        exportOptions.filenameEncoding = preset.filenameEncoding
        if exportOptions.filenameEncoding.locksEscapeMode {
            exportOptions.escapeMode = .fixed
        } else {
            exportOptions.escapeMode = .bestEffort
        }
    }

    private func inferredExportStylePreset() -> ExportStylePreset {
        switch exportOptions.filenameEncoding {
        case .standardUTF8:
            return .macOSModernLinux
        case .standardUTF8NoExtra:
            return .windows1011
        case .legacyJPCP932, .legacyJPCP932NoExtra, .legacyUTF16LE, .legacyEUCJP:
            return .legacyJapaneseWindows
        }
    }

    private func loadExportWizardPreference() -> (preset: ExportStylePreset?, skip: Bool) {
        let defaults = UserDefaults.standard
        let preset = defaults.string(forKey: StorageKeys.exportWizardDefaultPreset).flatMap(ExportStylePreset.init(rawValue:))
        let skip = defaults.bool(forKey: StorageKeys.exportWizardSkipsPrompt)
        return (preset, skip)
    }

    private func persistExportWizardPreference(preset: ExportStylePreset, skip: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: StorageKeys.exportWizardDefaultPreset)
        defaults.set(skip, forKey: StorageKeys.exportWizardSkipsPrompt)
    }

    func selectSavedPassword(id: UUID?) {
        exportOptions.savedPasswordID = id

        guard let id,
              let entry = savedPasswords.first(where: { $0.id == id }) else {
            exportOptions.password = ""
            return
        }

        exportOptions.password = entry.password
    }

    func savePassword(title: String, password: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, !trimmedPassword.isEmpty else { return }

        let entry = SavedPassword(title: trimmedTitle, password: trimmedPassword)
        savedPasswords.append(entry)
        savedPasswords.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        selectSavedPassword(id: entry.id)
    }

    func removeSavedPassword(id: UUID) {
        savedPasswords.removeAll { $0.id == id }
        if exportOptions.savedPasswordID == id {
            selectSavedPassword(id: nil)
        }
    }

    func hasNameConflict(_ proposedName: String, in parent: ZipNode, excluding excludedID: UUID? = nil) -> Bool {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return parent.children.contains { child in
            child.id != excludedID && child.name == trimmed
        }
    }

    private func uniqueName(for base: String, in folder: ZipNode) -> String {
        uniqueName(for: base, siblingNames: Set(folder.children.map(\.name)))
    }

    private func uniqueName(for base: String, siblingNames: Set<String>) -> String {
        guard siblingNames.contains(base) else { return base }

        let nsBase = base as NSString
        let stem = nsBase.deletingPathExtension
        let ext = nsBase.pathExtension
        var index = 2

        while true {
            let candidateStem = "\(stem) \(index)"
            let candidate = ext.isEmpty ? candidateStem : "\(candidateStem).\(ext)"
            if !siblingNames.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private func loadSavedPasswords() -> [SavedPassword] {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.savedPasswords) else {
            return []
        }

        return (try? JSONDecoder().decode([SavedPassword].self, from: data)) ?? []
    }

    private func persistSavedPasswords() {
        guard let data = try? JSONEncoder().encode(savedPasswords) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.savedPasswords)
    }

    private func normalizedDeletionIDs(from ids: [UUID]) -> [UUID] {
        let selectedSet = Set(ids)
        let nodes = ids.compactMap(findNode(id:))
        return nodes.filter { node in
            var current = node.parent
            while let ancestor = current {
                if selectedSet.contains(ancestor.id) {
                    return false
                }
                current = ancestor.parent
            }
            return true
        }.map(\.id)
    }
}
