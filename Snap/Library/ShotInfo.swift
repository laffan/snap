//
//  ShotInfo.swift
//  Snap
//
//  What a saved frame can say about itself: when it was taken, where, and on
//  what settings.
//
//  Read back out of the JPEG rather than kept in the sidecar, for the same
//  reason the look is written into EXIF — the file is the durable record, and
//  reading it means shots taken before any of this existed still describe
//  themselves.
//

import CoreLocation
import Foundation
import ImageIO

struct ShotInfo {

    var date: Date?
    var coordinate: CLLocationCoordinate2D?
    /// Seconds. Kept as the number so the label can decide how to read it.
    var exposureTime: Double?
    var iso: Int?

    var isEmpty: Bool {
        date == nil && coordinate == nil && exposureTime == nil && iso == nil
    }

    // MARK: - Reading

    /// Everything the develop screen shows, in one pass over the file's
    /// properties. `fallbackDate` is the shot's own timestamp, used when the
    /// capture carried no EXIF of its own — a preview frame, for instance.
    static func read(at url: URL, fallbackDate: Date? = nil) -> ShotInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return ShotInfo(date: fallbackDate)
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]

        var info = ShotInfo()
        info.date = date(from: exif) ?? fallbackDate
        info.coordinate = coordinate(
            from: properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        )
        info.exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        info.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue

        return info
    }

    /// The GPS block as it sits in a file, for copying from one frame to
    /// another. A re-filtered negative is the same photograph as the frame it
    /// came from, so it was taken in the same place.
    static func gpsProperties(at url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              !gps.isEmpty else {
            return nil
        }
        return gps
    }

    /// EXIF writes the time with no zone on it, so it is read as local — which
    /// is what it meant when the camera wrote it.
    private static func date(from exif: [String: Any]) -> Date? {
        let stamp = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized as String] as? String
        guard let stamp else { return nil }
        return exifFormatter.date(from: stamp)
    }

    /// The hemisphere is a separate tag from the number; without it every
    /// coordinate would land in the northern and eastern quarter of the world.
    private static func coordinate(from gps: [String: Any]?) -> CLLocationCoordinate2D? {
        guard let gps,
              let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue else {
            return nil
        }

        let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W"

        let coordinate = CLLocationCoordinate2D(latitude: south ? -latitude : latitude,
                                                longitude: west ? -longitude : longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // MARK: - Labels

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var dateLabel: String? {
        date.map { ShotInfo.dateFormatter.string(from: $0) }
    }

    /// What the coordinate reads as until the place it names comes back, and
    /// what it goes on reading as if nothing does.
    var coordinateLabel: String? {
        guard let coordinate else { return nil }
        return String(format: "%.3f° %@, %.3f° %@",
                      abs(coordinate.latitude), coordinate.latitude < 0 ? "S" : "N",
                      abs(coordinate.longitude), coordinate.longitude < 0 ? "W" : "E")
    }

    /// A shutter reads as a fraction until it passes a second, and as seconds
    /// after that — the way it is spoken rather than the way it is stored.
    var shutterLabel: String? {
        guard let exposureTime, exposureTime > 0 else { return nil }
        if exposureTime >= 1 {
            let whole = exposureTime.rounded()
            return abs(exposureTime - whole) < 0.05
                ? String(format: "%.0fs", whole)
                : String(format: "%.1fs", exposureTime)
        }
        return "1/\(Int((1 / exposureTime).rounded()))"
    }

    var isoLabel: String? {
        iso.map { "ISO \($0)" }
    }
}

// MARK: - Place names

/// Turns a coordinate into the name of somewhere.
///
/// Reverse geocoding is a network round trip and Apple rate-limits it, so every
/// answer is kept — the develop screen asks again for the same frame every time
/// it opens, and a roll shot in one afternoon is mostly one place.
actor PlaceNames {

    static let shared = PlaceNames()

    private var cache: [String: String] = [:]

    /// Rounded to about a hundred metres, which is the distance at which the
    /// answer stops changing.
    private func key(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    func name(latitude: Double, longitude: Double) async -> String? {
        let key = key(latitude, longitude)
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
              let name = PlaceNames.name(for: placemark) else {
            return nil
        }

        cache[key] = name
        return name
    }

    /// Town and region, which is how a photograph is usually placed out loud.
    /// Falls back through what the placemark does have, and never repeats
    /// itself — a city that is its own region reads once.
    private static func name(for placemark: CLPlacemark) -> String? {
        let town = placemark.locality
            ?? placemark.subLocality
            ?? placemark.subAdministrativeArea
            ?? placemark.name
        let region = placemark.administrativeArea ?? placemark.country

        let parts = [town, region].compactMap { $0 }
        var seen: [String] = []
        for part in parts where !seen.contains(part) { seen.append(part) }
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
    }
}
