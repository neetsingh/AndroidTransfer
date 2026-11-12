import CoreLocation
import Foundation
import TransferCore

/// Turns GPS coordinates into place names. Lookups are cached per ~1 km area and run one at a time,
/// because Apple's geocoding service throttles rapid bursts of requests.
@MainActor
final class PlaceNamer {
    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    func name(for coordinate: GPSCoordinate) async -> String {
        if let cached = cache[coordinate.cacheKey] { return cached }
        let name: String
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            name = placemarks.first.flatMap(Self.title(for:)) ?? coordinate.displayText
            cache[coordinate.cacheKey] = name
        } catch {
            // Offline or throttled: show the coordinates and try again next time.
            NSLog("Reverse geocoding failed for %@: %@", coordinate.displayText, error.localizedDescription)
            name = coordinate.displayText
        }
        return name
    }

    func cancel() {
        geocoder.cancelGeocode()
    }

    private static func title(for placemark: CLPlacemark) -> String? {
        let place = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? placemark.name
        let parts = [place, placemark.country].compactMap { $0 }.filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
