import Foundation
import ImageIO

public enum FileGrouping: String, CaseIterable, Hashable {
    case none = "None"
    case date = "Date"
    case location = "Location"
}

public struct GPSCoordinate: Hashable {
    public let latitude: Double
    public let longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Key used to share one place-name lookup between photos taken within roughly a kilometre of each other.
    public var cacheKey: String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    /// Rounded like `cacheKey`, so photos fall into the same group when no place name is available.
    public var displayText: String {
        String(format: "%.2f°%@, %.2f°%@",
               abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

public enum PhotoMetadataResult: Hashable {
    case coordinate(GPSCoordinate)
    /// Metadata was readable but contains no usable GPS position.
    case noLocation
    /// The data could not be parsed as an image with metadata (for example, it is truncated).
    case unreadable
}

public enum PhotoMetadata {
    public static func location(fromImageData data: Data) -> PhotoMetadataResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              !properties.isEmpty else {
            return .unreadable
        }
        return location(fromProperties: properties)
    }

    public static func location(fromProperties properties: [CFString: Any]) -> PhotoMetadataResult {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = number(gps[kCGImagePropertyGPSLatitude]),
              var longitude = number(gps[kCGImagePropertyGPSLongitude]) else {
            let hasMetadata = properties[kCGImagePropertyExifDictionary] != nil
                || properties[kCGImagePropertyPixelWidth] != nil
            return hasMetadata ? .noLocation : .unreadable
        }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = -abs(latitude) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = -abs(longitude) }
        guard let coordinate = GPSCoordinate(latitude: latitude, longitude: longitude) else { return .noLocation }
        return .coordinate(coordinate)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public enum PhotoLocation: Hashable, Codable {
    case place(String)
    case unknown
}

public struct FileGroup: Identifiable {
    public let id: String
    public let title: String
    public let files: [DeviceFile]

    public init(id: String, title: String, files: [DeviceFile]) {
        self.id = id
        self.title = title
        self.files = files
    }
}

public enum FileGrouper {
    public static let pendingLocationTitle = "Finding location…"
    public static let unknownLocationTitle = "No location"

    /// `locations` holds a resolved place for files that were scanned; files without an entry are still pending.
    public static func groups(
        _ files: [DeviceFile],
        by grouping: FileGrouping,
        locations: [DeviceFile.ID: PhotoLocation] = [:],
        sort: FileSort = .nameAscending,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [FileGroup] {
        guard grouping != .none else {
            return files.isEmpty ? [] : [FileGroup(id: "all", title: "", files: FileOrdering.sorted(files, by: sort))]
        }
        let folders = files.filter(\.isFolder)
        let items = files.filter { !$0.isFolder }
        var result: [FileGroup] = []
        if !folders.isEmpty { result.append(FileGroup(id: "folders", title: "Folders", files: FileOrdering.sorted(folders, by: sort))) }
        switch grouping {
        case .none:
            break
        case .date:
            result += dateGroups(items, sort: sort, calendar: calendar, now: now)
        case .location:
            result += locationGroups(items, locations: locations, sort: sort)
        }
        return result
    }

    private static func dateGroups(_ files: [DeviceFile], sort: FileSort, calendar: Calendar, now: Date) -> [FileGroup] {
        var byDay: [Date: [DeviceFile]] = [:]
        var undated: [DeviceFile] = []
        for file in files {
            if let date = file.modifiedAt {
                byDay[calendar.startOfDay(for: date), default: []].append(file)
            } else {
                undated.append(file)
            }
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let days = sort == .dateOldest ? byDay.keys.sorted(by: <) : byDay.keys.sorted(by: >)
        var groups = days.map { day -> FileGroup in
            let title: String
            if day == today {
                title = "Today"
            } else if day == yesterday {
                title = "Yesterday"
            } else {
                var style = Date.FormatStyle(date: .complete, time: .omitted)
                style.calendar = calendar
                style.timeZone = calendar.timeZone
                title = day.formatted(style)
            }
            return FileGroup(id: "day-\(Int(day.timeIntervalSince1970))", title: title, files: FileOrdering.sorted(byDay[day] ?? [], by: sort))
        }
        if !undated.isEmpty {
            groups.append(FileGroup(id: "no-date", title: "No date", files: FileOrdering.sorted(undated, by: sort)))
        }
        return groups
    }

    private static func locationGroups(
        _ files: [DeviceFile], locations: [DeviceFile.ID: PhotoLocation], sort: FileSort
    ) -> [FileGroup] {
        var byPlace: [String: [DeviceFile]] = [:]
        var pending: [DeviceFile] = []
        var unknown: [DeviceFile] = []
        for file in files {
            guard file.mediaKind == .image else {
                unknown.append(file)
                continue
            }
            switch locations[file.id] {
            case .place(let name)?: byPlace[name, default: []].append(file)
            case .unknown?: unknown.append(file)
            case nil: pending.append(file)
            }
        }
        var groups = byPlace.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileGroup(id: "place-\($0)", title: $0, files: FileOrdering.sorted(byPlace[$0] ?? [], by: sort)) }
        if !pending.isEmpty {
            groups.append(FileGroup(id: "pending-location", title: pendingLocationTitle, files: FileOrdering.sorted(pending, by: sort)))
        }
        if !unknown.isEmpty {
            groups.append(FileGroup(id: "no-location", title: unknownLocationTitle, files: FileOrdering.sorted(unknown, by: sort)))
        }
        return groups
    }
}
