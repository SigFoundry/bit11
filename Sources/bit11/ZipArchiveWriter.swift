import Foundation
import zlib

struct ExportProgressPlan {
    let totalEntries: Int
    let totalUncompressedBytes: UInt64
}

struct ExportProgressSnapshot {
    let currentPath: String
    let completedEntries: Int
    let totalEntries: Int
    let completedUncompressedBytes: UInt64
    let totalUncompressedBytes: UInt64

    var fractionCompleted: Double? {
        if totalUncompressedBytes > 0 {
            return min(max(Double(completedUncompressedBytes) / Double(totalUncompressedBytes), 0), 1)
        }
        guard totalEntries > 0 else { return nil }
        return min(max(Double(completedEntries) / Double(totalEntries), 0), 1)
    }
}

struct ZipArchiveWriter: @unchecked Sendable {
    private static let maximumStandardZIP32Value: UInt64 = 0xFFFF_FFFF
    private static let maximumStandardZIPEntryCount: Int = 0xFFFF

    private let root: ZipNode
    private let options: ExportOptions

    init(root: ZipNode, options: ExportOptions) throws {
        self.root = root
        self.options = options
    }

    func makeProgressPlan() throws -> ExportProgressPlan {
        try validateStandardZIPLimits()
        let entries = try collectEntries()
        guard !entries.isEmpty else {
            throw ExportError.noContent
        }
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        return ExportProgressPlan(totalEntries: entries.count, totalUncompressedBytes: totalBytes)
    }

    func makeArchiveData() throws -> Data {
        try validateStandardZIPLimits()
        let entries = try collectEntries()
        guard !entries.isEmpty else {
            throw ExportError.noContent
        }

        var archive = Data()
        var centralDirectory = Data()
        var offset: UInt64 = 0

        for entry in entries {
            let encodedFilename = try FilenameEncoder(options: options).encode(path: entry.path)
            let rawData = try entry.loadData()
            let compressedData = try compress(rawData, preset: options.compression, path: entry.path)
            let crc = CRC32.checksum(for: rawData)
            let encryptedPayload = try encryptIfNeeded(
                compressedData,
                password: options.passwordOrNil,
                crc32: crc
            )

            try ensureZip32Compatible(entry: entry, compressedSize: encryptedPayload.count)
            let versionNeeded: UInt16 = 20
            let flags = generalPurposeFlags(passwordProtected: options.passwordOrNil != nil)
            let method = entry.isDirectory || options.compression == .none ? UInt16(0) : UInt16(8)
            let modTime = dosTime()
            let localHeaderOffset = try zip32(offset)

            var localHeader = Data()
            localHeader.appendUInt32LE(0x04034b50)
            localHeader.appendUInt16LE(versionNeeded)
            localHeader.appendUInt16LE(flags)
            localHeader.appendUInt16LE(method)
            localHeader.appendUInt16LE(modTime.time)
            localHeader.appendUInt16LE(modTime.date)
            localHeader.appendUInt32LE(crc)
            localHeader.appendUInt32LE(try zip32(UInt64(encryptedPayload.count)))
            localHeader.appendUInt32LE(try zip32(entry.uncompressedSize))
            localHeader.appendUInt16LE(UInt16(encodedFilename.mainData.count))
            localHeader.appendUInt16LE(UInt16(encodedFilename.extraField.count))
            localHeader.append(encodedFilename.mainData)
            localHeader.append(encodedFilename.extraField)
            localHeader.append(encryptedPayload)
            archive.append(localHeader)

            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(0x031E)
            centralDirectory.appendUInt16LE(versionNeeded)
            centralDirectory.appendUInt16LE(flags)
            centralDirectory.appendUInt16LE(method)
            centralDirectory.appendUInt16LE(modTime.time)
            centralDirectory.appendUInt16LE(modTime.date)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(try zip32(UInt64(encryptedPayload.count)))
            centralDirectory.appendUInt32LE(try zip32(entry.uncompressedSize))
            centralDirectory.appendUInt16LE(UInt16(encodedFilename.mainData.count))
            centralDirectory.appendUInt16LE(UInt16(encodedFilename.extraField.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(entry.isDirectory ? 0x10 : 0)
            centralDirectory.appendUInt32LE(entry.isDirectory ? 0x10 : 0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(encodedFilename.mainData)
            centralDirectory.append(encodedFilename.extraField)

            offset += UInt64(localHeader.count)
        }

        let centralDirectoryOffset = offset
        try ensureArchiveZip32Compatible(offset: centralDirectoryOffset, centralDirectorySize: UInt64(centralDirectory.count), entryCount: entries.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt32LE(try zip32(UInt64(centralDirectory.count)))
        archive.appendUInt32LE(try zip32(centralDirectoryOffset))
        archive.appendUInt16LE(0)

        return archive
    }

    func write(to destination: URL, progress: ((ExportProgressSnapshot) -> Void)? = nil) throws {
        try validateStandardZIPLimits()
        let entries = try collectEntries()
        guard !entries.isEmpty else {
            throw ExportError.noContent
        }

        let plan = ExportProgressPlan(
            totalEntries: entries.count,
            totalUncompressedBytes: entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        )

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)

        var centralDirectory = Data()
        var offset: UInt64 = 0
        var completedEntries = 0
        var completedBytes: UInt64 = 0

        progress?(ExportProgressSnapshot(
            currentPath: "",
            completedEntries: 0,
            totalEntries: plan.totalEntries,
            completedUncompressedBytes: 0,
            totalUncompressedBytes: plan.totalUncompressedBytes
        ))

        for entry in entries {
            let encodedFilename = try FilenameEncoder(options: options).encode(path: entry.path)
            let rawData = try entry.loadData()
            let compressedData = try compress(rawData, preset: options.compression, path: entry.path)
            let crc = CRC32.checksum(for: rawData)
            let encryptedPayload = try encryptIfNeeded(
                compressedData,
                password: options.passwordOrNil,
                crc32: crc
            )

            try ensureZip32Compatible(entry: entry, compressedSize: encryptedPayload.count)
            let versionNeeded: UInt16 = 20
            let flags = generalPurposeFlags(passwordProtected: options.passwordOrNil != nil)
            let method = entry.isDirectory || options.compression == .none ? UInt16(0) : UInt16(8)
            let modTime = dosTime()
            let localHeaderOffset = try zip32(offset)

            var localHeader = Data()
            localHeader.appendUInt32LE(0x04034b50)
            localHeader.appendUInt16LE(versionNeeded)
            localHeader.appendUInt16LE(flags)
            localHeader.appendUInt16LE(method)
            localHeader.appendUInt16LE(modTime.time)
            localHeader.appendUInt16LE(modTime.date)
            localHeader.appendUInt32LE(crc)
            localHeader.appendUInt32LE(try zip32(UInt64(encryptedPayload.count)))
            localHeader.appendUInt32LE(try zip32(entry.uncompressedSize))
            localHeader.appendUInt16LE(UInt16(encodedFilename.mainData.count))
            localHeader.appendUInt16LE(UInt16(encodedFilename.extraField.count))
            localHeader.append(encodedFilename.mainData)
            localHeader.append(encodedFilename.extraField)

            try writeData(localHeader, to: handle)
            try writeData(encryptedPayload, to: handle)
            offset += UInt64(localHeader.count + encryptedPayload.count)

            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(0x031E)
            centralDirectory.appendUInt16LE(versionNeeded)
            centralDirectory.appendUInt16LE(flags)
            centralDirectory.appendUInt16LE(method)
            centralDirectory.appendUInt16LE(modTime.time)
            centralDirectory.appendUInt16LE(modTime.date)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(try zip32(UInt64(encryptedPayload.count)))
            centralDirectory.appendUInt32LE(try zip32(entry.uncompressedSize))
            centralDirectory.appendUInt16LE(UInt16(encodedFilename.mainData.count))
            centralDirectory.appendUInt16LE(UInt16(encodedFilename.extraField.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(entry.isDirectory ? 0x10 : 0)
            centralDirectory.appendUInt32LE(entry.isDirectory ? 0x10 : 0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(encodedFilename.mainData)
            centralDirectory.append(encodedFilename.extraField)

            completedEntries += 1
            completedBytes += entry.uncompressedSize
            progress?(ExportProgressSnapshot(
                currentPath: entry.path,
                completedEntries: completedEntries,
                totalEntries: plan.totalEntries,
                completedUncompressedBytes: completedBytes,
                totalUncompressedBytes: plan.totalUncompressedBytes
            ))
        }

        let centralDirectoryOffset = offset
        try ensureArchiveZip32Compatible(offset: centralDirectoryOffset, centralDirectorySize: UInt64(centralDirectory.count), entryCount: entries.count)
        try writeData(centralDirectory, to: handle)

        var endOfCentralDirectory = Data()
        endOfCentralDirectory.appendUInt32LE(0x06054b50)
        endOfCentralDirectory.appendUInt16LE(0)
        endOfCentralDirectory.appendUInt16LE(0)
        endOfCentralDirectory.appendUInt16LE(UInt16(entries.count))
        endOfCentralDirectory.appendUInt16LE(UInt16(entries.count))
        endOfCentralDirectory.appendUInt32LE(try zip32(UInt64(centralDirectory.count)))
        endOfCentralDirectory.appendUInt32LE(try zip32(centralDirectoryOffset))
        endOfCentralDirectory.appendUInt16LE(0)
        try writeData(endOfCentralDirectory, to: handle)
    }

    private func writeData(_ data: Data, to handle: FileHandle) throws {
        if #available(macOS 10.15.4, *) {
            try handle.write(contentsOf: data)
        } else {
            handle.write(data)
        }
    }

    private func validateStandardZIPLimits() throws {
        let summary = try makeArchiveSummary()

        if summary.entryCount > Self.maximumStandardZIPEntryCount {
            throw ExportError.tooManyEntries
        }

        if summary.totalUncompressedSize > Self.maximumStandardZIP32Value {
            throw ExportError.zip64RequiredForArchive
        }
    }

    private func makeArchiveSummary() throws -> (entryCount: Int, totalUncompressedSize: UInt64) {
        var entryCount = 0
        var totalUncompressedSize: UInt64 = 0
        try appendSummary(from: root, currentPath: "", entryCount: &entryCount, totalUncompressedSize: &totalUncompressedSize)
        return (entryCount, totalUncompressedSize)
    }

    private func appendSummary(
        from node: ZipNode,
        currentPath: String,
        entryCount: inout Int,
        totalUncompressedSize: inout UInt64
    ) throws {
        for child in node.sortedChildren {
            let path = currentPath.isEmpty ? child.name : "\(currentPath)/\(child.name)"

            if child.isDirectory {
                let shouldIncludeDirectory = !options.ignoreEmptyFolders || hasExportableDescendant(in: child)
                guard shouldIncludeDirectory else { continue }
                entryCount += 1
                try appendSummary(from: child, currentPath: path, entryCount: &entryCount, totalUncompressedSize: &totalUncompressedSize)
            } else {
                guard let url = child.sourceURL else {
                    throw ExportError.fileReadFailed(URL(fileURLWithPath: child.name))
                }
                let fileSize64 = try uncompressedSize(for: url)
                if fileSize64 > Self.maximumStandardZIP32Value {
                    throw ExportError.zip64RequiredForEntry(path)
                }
                entryCount += 1
                totalUncompressedSize += fileSize64
                if totalUncompressedSize > Self.maximumStandardZIP32Value {
                    throw ExportError.zip64RequiredForArchive
                }
            }
        }
    }

    private func collectEntries() throws -> [ArchiveEntry] {
        var results: [ArchiveEntry] = []
        try appendEntries(from: root, currentPath: "", into: &results)
        return results
    }

    private func appendEntries(from node: ZipNode, currentPath: String, into results: inout [ArchiveEntry]) throws {
        for child in node.sortedChildren {
            let path = currentPath.isEmpty ? child.name : "\(currentPath)/\(child.name)"

            if child.isDirectory {
                let shouldIncludeDirectory = !options.ignoreEmptyFolders || hasExportableDescendant(in: child)
                guard shouldIncludeDirectory else { continue }

                results.append(ArchiveEntry(path: path + "/", sourceURL: nil, uncompressedSize: 0, isDirectory: true))
                try appendEntries(from: child, currentPath: path, into: &results)
            } else {
                guard let url = child.sourceURL else {
                    throw ExportError.fileReadFailed(URL(fileURLWithPath: child.name))
                }
                let fileSize64 = try uncompressedSize(for: url)
                if fileSize64 > Self.maximumStandardZIP32Value {
                    throw ExportError.zip64RequiredForEntry(path)
                }
                results.append(ArchiveEntry(path: path, sourceURL: url, uncompressedSize: fileSize64, isDirectory: false))
            }
        }
    }

    private func uncompressedSize(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        let fileSize = values.totalFileSize ?? values.fileSize ?? 0
        return UInt64(max(fileSize, 0))
    }

    private func hasExportableDescendant(in node: ZipNode) -> Bool {
        for child in node.children {
            if child.isDirectory {
                if hasExportableDescendant(in: child) {
                    return true
                }
            } else {
                return true
            }
        }

        return false
    }

    private func ensureZip32Compatible(entry: ArchiveEntry, compressedSize: Int) throws {
        if entry.uncompressedSize > Self.maximumStandardZIP32Value {
            throw ExportError.zip64RequiredForEntry(entry.path)
        }

        if UInt64(compressedSize) > Self.maximumStandardZIP32Value {
            throw ExportError.zip64RequiredForArchive
        }
    }

    private func ensureArchiveZip32Compatible(offset: UInt64, centralDirectorySize: UInt64, entryCount: Int) throws {
        if entryCount > Self.maximumStandardZIPEntryCount {
            throw ExportError.tooManyEntries
        }
        if offset > Self.maximumStandardZIP32Value || centralDirectorySize > Self.maximumStandardZIP32Value {
            throw ExportError.zip64RequiredForArchive
        }
        let finalSize = offset + centralDirectorySize + 22
        if finalSize > Self.maximumStandardZIP32Value {
            throw ExportError.zip64RequiredForArchive
        }
    }

    private func zip32(_ value: UInt64) throws -> UInt32 {
        guard value <= Self.maximumStandardZIP32Value else {
            throw ExportError.zip64RequiredForArchive
        }
        return UInt32(value)
    }

    private func generalPurposeFlags(passwordProtected: Bool) -> UInt16 {
        var flags: UInt16 = 0
        if passwordProtected {
            flags |= 1 << 0
        }
        if options.filenameEncoding.usesEFS {
            flags |= 1 << 11
        }
        return flags
    }

    private func compress(_ data: Data, preset: CompressionPreset, path: String) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard preset != .none else { return data }
        return try Deflater.deflate(data: data, level: preset.zlibLevel, path: path)
    }

    private func encryptIfNeeded(_ data: Data, password: String?, crc32: UInt32) throws -> Data {
        guard let password else { return data }
        return ZipCrypto.encrypt(data: data, password: password, crc32: crc32)
    }
}

private struct ArchiveEntry {
    let path: String
    let sourceURL: URL?
    let uncompressedSize: UInt64
    let isDirectory: Bool

    func loadData() throws -> Data {
        guard let sourceURL else { return Data() }
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw ExportError.fileReadFailed(sourceURL)
        }
        return data
    }
}

private struct EncodedFilename {
    let mainData: Data
    let extraField: Data
}

private struct FilenameEncoder {
    let options: ExportOptions

    func encode(path: String) throws -> EncodedFilename {
        let mainData: Data

        switch options.filenameEncoding {
        case .standardUTF8, .standardUTF8NoExtra:
            guard let data = path.data(using: .utf8) else {
                throw ExportError.cannotEncodeFilename(path)
            }
            mainData = data
        case .legacyUTF16LE:
            mainData = Data(path.utf16LittleEndianBytes)
        case .legacyJPCP932, .legacyJPCP932NoExtra:
            mainData = try encodeLegacy(path: path, encoding: .cp932)
        case .legacyEUCJP:
            mainData = try encodeLegacy(path: path, encoding: .eucJP)
        }

        let extraField = options.filenameEncoding.usesUnicodePathExtra
            ? unicodePathExtraField(mainFieldData: mainData, originalPath: path)
            : Data()

        return EncodedFilename(mainData: mainData, extraField: extraField)
    }

    private func encodeLegacy(path: String, encoding: String.Encoding) throws -> Data {
        var data = Data()
        for scalar in path.unicodeScalars {
            data.append(try encodeScalar(scalar, encoding: encoding))
        }
        return data
    }

    private func encodeScalar(_ scalar: UnicodeScalar, encoding: String.Encoding) throws -> Data {
        let char = String(scalar)
        if let encoded = char.data(using: encoding) {
            return encoded
        }

        switch options.escapeMode {
        case .fixed:
            if let utf8 = char.data(using: .utf8) {
                return utf8
            }
        case .unicodeCodepoint:
            return Data("U+\(String(format: "%04X", scalar.value))".utf8)
        case .bestEffort:
            if let replacement = bestEffortReplacement(for: scalar),
               let encoded = replacement.data(using: encoding) {
                return encoded
            }
            return Data("U+\(String(format: "%04X", scalar.value))".utf8)
        }

        throw ExportError.cannotEncodeFilename(char)
    }

    private func bestEffortReplacement(for scalar: UnicodeScalar) -> String? {
        switch scalar.value {
        case 0x9AD9:
            "高"
        default:
            nil
        }
    }

    private func unicodePathExtraField(mainFieldData: Data, originalPath: String) -> Data {
        var body = Data()
        body.append(0x01)
        body.appendUInt32LE(CRC32.checksum(for: mainFieldData))
        body.append(Data(originalPath.utf8))

        var field = Data()
        field.appendUInt16LE(0x7075)
        field.appendUInt16LE(UInt16(body.count))
        field.append(body)
        return field
    }
}

private enum Deflater {
    static func deflate(data: Data, level: Int32, path: String) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initResult == Z_OK else {
            throw ExportError.compressionFailed(path)
        }

        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let chunkSize = 64 * 1024

            while true {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                output.append(chunk, count: produced)

                if status == Z_STREAM_END {
                    break
                }

                if status != Z_OK {
                    throw ExportError.compressionFailed(path)
                }
            }

            return output
        }
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB88320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()

    static func checksum(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let lookup = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[lookup] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func update(crc: UInt32, with byte: UInt8) -> UInt32 {
        let lookup = Int((crc ^ UInt32(byte)) & 0xFF)
        return table[lookup] ^ (crc >> 8)
    }
}

private enum ZipCrypto {
    static func encrypt(data: Data, password: String, crc32: UInt32) -> Data {
        var keys = Keys()
        for byte in password.utf8 {
            keys.update(with: byte)
        }

        var header = Data((0..<11).map { _ in UInt8.random(in: 0...255) })
        header.append(UInt8((crc32 >> 24) & 0xFF))

        var encrypted = Data()
        encrypted.append(contentsOf: header.map { keys.encrypt($0) })
        encrypted.append(contentsOf: data.map { keys.encrypt($0) })
        return encrypted
    }

    private struct Keys {
        var key0: UInt32 = 0x12345678
        var key1: UInt32 = 0x23456789
        var key2: UInt32 = 0x34567890

        mutating func update(with byte: UInt8) {
            key0 = CRC32.update(crc: key0, with: byte)
            key1 = (key1 &+ (key0 & 0xFF)) &* 134775813 &+ 1
            key2 = CRC32.update(crc: key2, with: UInt8((key1 >> 24) & 0xFF))
        }

        mutating func encrypt(_ byte: UInt8) -> UInt8 {
            let temp = decryptByte()
            let encrypted = byte ^ temp
            update(with: byte)
            return encrypted
        }

        private func decryptByte() -> UInt8 {
            let temp = key2 | 2
            return UInt8(((temp &* (temp ^ 1)) >> 8) & 0xFF)
        }
    }
}

private func dosTime(date: Date = .now) -> (time: UInt16, date: UInt16) {
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let year = max((components.year ?? 1980) - 1980, 0)
    let month = components.month ?? 1
    let day = components.day ?? 1
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    let second = (components.second ?? 0) / 2

    let dosDate = UInt16((year << 9) | (month << 5) | day)
    let dosTime = UInt16((hour << 11) | (minute << 5) | second)
    return (dosTime, dosDate)
}

private extension CompressionPreset {
    var zlibLevel: Int32 {
        switch self {
        case .none: Z_NO_COMPRESSION
        case .fast: Z_BEST_SPEED
        case .balanced: Z_DEFAULT_COMPRESSION
        case .maximum: Z_BEST_COMPRESSION
        }
    }
}

private extension FilenameEncoding {
    var usesEFS: Bool {
        switch self {
        case .standardUTF8, .standardUTF8NoExtra:
            true
        case .legacyJPCP932, .legacyJPCP932NoExtra, .legacyUTF16LE, .legacyEUCJP:
            false
        }
    }

    var usesUnicodePathExtra: Bool {
        switch self {
        case .standardUTF8, .legacyJPCP932:
            true
        case .standardUTF8NoExtra, .legacyJPCP932NoExtra, .legacyUTF16LE, .legacyEUCJP:
            false
        }
    }
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { codeUnit in
            let littleEndian = codeUnit.littleEndian
            return [
                UInt8(truncatingIfNeeded: littleEndian & 0x00FF),
                UInt8(truncatingIfNeeded: littleEndian >> 8),
            ]
        }
    }
}

extension String.Encoding {
    static let cp932 = String.Encoding.shiftJIS

    static let eucJP = String.Encoding.japaneseEUC
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value & 0x00FF),
            UInt8(truncatingIfNeeded: value >> 8),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value & 0x000000FF),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
