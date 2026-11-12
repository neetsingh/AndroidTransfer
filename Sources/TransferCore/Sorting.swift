import CryptoKit
import Foundation

public enum FileSort: String, CaseIterable, Hashable {
    case nameAscending = "Name (A–Z)"
    case nameDescending = "Name (Z–A)"
    case dateNewest = "Date (Newest First)"
    case dateOldest = "Date (Oldest First)"

    public var isByDate: Bool { self == .dateNewest || self == .dateOldest }
}

extension FileOrdering {
    /// Folders always come first. Items without a date sort after dated items in both date orders.
    public static func sorted(_ files: [DeviceFile], by sort: FileSort) -> [DeviceFile] {
        files.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            switch sort {
            case .nameAscending:
                return nameOrder(lhs, rhs)
            case .nameDescending:
                return nameOrder(rhs, lhs)
            case .dateNewest, .dateOldest:
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?) where left != right:
                    return sort == .dateNewest ? left > right : left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return nameOrder(lhs, rhs)
                }
            }
        }
    }

    private static func nameOrder(_ lhs: DeviceFile, _ rhs: DeviceFile) -> Bool {
        let result = lhs.name.localizedStandardCompare(rhs.name)
        return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
    }
}

/// Identifies a file's contents across connections. MTP object IDs can change after reconnecting,
/// so the key combines the device, the file's path, size and modification time instead.
public struct MediaCacheKey: Hashable {
    public let value: String

    public init(device: String, storageID: UInt32, path: [String], file: DeviceFile) {
        let modified = file.modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let identity = ([device, String(storageID)] + path + [file.name, String(file.size), modified])
            .joined(separator: "\u{1F}")
        value = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CachedThumbnail: Equatable {
    case data(Data)
    /// Neither the device nor the Mac could produce a preview for this file; don't try again.
    case unavailable
}

/// Disk cache for thumbnails and photo locations. Each thumbnail is a file named by its key; an empty file
/// records that the device had no thumbnail. Locations are kept in one JSON file.
public actor MediaCache {
    private let directory: URL
    // Version 1 recorded every file without a phone-supplied thumbnail as unavailable; v2 also holds Mac-made previews.
    private var thumbnailDirectory: URL { directory.appendingPathComponent("thumbnails-v2", isDirectory: true) }
    private var legacyThumbnailDirectory: URL { directory.appendingPathComponent("thumbnails", isDirectory: true) }
    private var locationsFile: URL { directory.appendingPathComponent("locations.json") }
    private var locations: [String: PhotoLocation]?
    private var unsavedLocations = 0

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("local.androidtransfer.app", isDirectory: true)
    }

    public func thumbnail(for key: MediaCacheKey) -> CachedThumbnail? {
        guard let data = try? Data(contentsOf: thumbnailURL(key)) else { return nil }
        return data.isEmpty ? .unavailable : .data(data)
    }

    public func storeThumbnail(_ thumbnail: CachedThumbnail, for key: MediaCacheKey) {
        do {
            try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            switch thumbnail {
            case .data(let data): try data.write(to: thumbnailURL(key), options: .atomic)
            case .unavailable: try Data().write(to: thumbnailURL(key), options: .atomic)
            }
        } catch {
            NSLog("Could not cache thumbnail: %@", error.localizedDescription)
        }
    }

    public func location(for key: MediaCacheKey) -> PhotoLocation? {
        loadedLocations()[key.value]
    }

    public func storeLocation(_ location: PhotoLocation, for key: MediaCacheKey) {
        var all = loadedLocations()
        all[key.value] = location
        locations = all
        unsavedLocations += 1
        if unsavedLocations >= 25 { flush() }
    }

    public func flush() {
        guard unsavedLocations > 0, let locations else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(locations).write(to: locationsFile, options: .atomic)
            unsavedLocations = 0
        } catch {
            NSLog("Could not save cached locations: %@", error.localizedDescription)
        }
    }

    public func clear() {
        locations = [:]
        unsavedLocations = 0
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            NSLog("Could not clear cache: %@", error.localizedDescription)
        }
    }

    /// Removes the least recently written thumbnails once the cache grows beyond `maxBytes`.
    public func prune(maxBytes: Int) {
        if FileManager.default.fileExists(atPath: legacyThumbnailDirectory.path) {
            do { try FileManager.default.removeItem(at: legacyThumbnailDirectory) }
            catch { NSLog("Could not remove old thumbnail cache: %@", error.localizedDescription) }
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: thumbnailDirectory, includingPropertiesForKeys: keys
        ) else { return }
        var entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        entries.sort { $0.2 < $1.2 }
        let target = maxBytes * 3 / 4
        for (url, size, _) in entries where total > target {
            do {
                try FileManager.default.removeItem(at: url)
                total -= size
            } catch {
                NSLog("Could not prune cached thumbnail: %@", error.localizedDescription)
            }
        }
    }

    private func thumbnailURL(_ key: MediaCacheKey) -> URL {
        thumbnailDirectory.appendingPathComponent(key.value)
    }

    private func loadedLocations() -> [String: PhotoLocation] {
        if let locations { return locations }
        var loaded: [String: PhotoLocation] = [:]
        if let data = try? Data(contentsOf: locationsFile) {
            do { loaded = try JSONDecoder().decode([String: PhotoLocation].self, from: data) }
            catch { NSLog("Ignoring unreadable location cache: %@", error.localizedDescription) }
        }
        locations = loaded
        return loaded
    }
}
