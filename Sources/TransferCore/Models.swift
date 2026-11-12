import Foundation
import UniformTypeIdentifiers

public struct Storage: Identifiable, Hashable {
    public let id: UInt32
    public let name: String
    public let freeBytes: UInt64

    public init(id: UInt32, name: String, freeBytes: UInt64) {
        self.id = id
        self.name = name
        self.freeBytes = freeBytes
    }
}

public struct DeviceFile: Identifiable, Hashable {
    public let id: UInt32
    public let name: String
    public let size: UInt64
    public let isFolder: Bool
    public let modifiedAt: Date?

    public var mediaKind: MediaKind? {
        guard !isFolder else { return nil }
        return MediaKind(filename: name)
    }

    public init(id: UInt32, name: String, size: UInt64, isFolder: Bool, modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
    }
}

public enum MTPDate {
    // MTP devices report 0 (or negative values) when no modification date is known.
    public static func date(fromUnixTime seconds: Int) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }
}

public enum MediaKind: Hashable {
    case image
    case video
    case audio

    public init?(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }
}

public struct Folder: Hashable {
    public let id: UInt32
    public let name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

public enum FileOrdering {
    public static func sorted(_ files: [DeviceFile]) -> [DeviceFile] {
        files.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
    }
}

public enum DownloadNaming {
    /// Returns a destination in `folder` that is neither on disk nor in `reserved`, adding " (2)", " (3)"… before the extension.
    public static func uniqueDestination(
        for name: String, in folder: URL, reserved: Set<String> = [],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = URL(fileURLWithPath: name).lastPathComponent
        let safe = base.isEmpty || base == "." || base == ".." ? "Untitled" : base
        let stem = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe)
        var index = 2
        while exists(candidate) || reserved.contains(candidate.lastPathComponent.lowercased()) {
            let numbered = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }
}

public struct DeletionResult {
    public let deleted: [DeviceFile]
    public let failed: DeviceFile?
    public let error: Error?
}

public enum DeletionRunner {
    @MainActor
    public static func run(
        files: [DeviceFile],
        delete: (DeviceFile) async throws -> Void,
        didDelete: (Int, Int) -> Void
    ) async -> DeletionResult {
        var deleted: [DeviceFile] = []
        for file in files {
            do {
                try await delete(file)
                deleted.append(file)
                didDelete(deleted.count, files.count)
            } catch {
                return DeletionResult(deleted: deleted, failed: file, error: error)
            }
        }
        return DeletionResult(deleted: deleted, failed: nil, error: nil)
    }
}
