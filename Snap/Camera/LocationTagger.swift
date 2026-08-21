//
//  LocationTagger.swift
//  Snap
//
//  Where a photograph was taken, ready to be written into its EXIF.
//
//  iOS does not put GPS into a capture on its own — `AVCapturePhoto.metadata`
//  carries exposure, lens and timestamp but never a coordinate, so anything
//  that wants one has to ask CoreLocation and write it in. That is all this
//  does: hold the most recent fix and hand it over as an EXIF GPS dictionary
//  at the moment the shutter fires.
//

import CoreLocation
import Foundation
import ImageIO

final class LocationTagger: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    /// Written on the main queue by the delegate, read on whichever queue the
    /// capture finished on.
    private let lock = NSLock()
    private var latest: CLLocation?

    /// A photograph is placed to the street, not to the doorstep. Hundreds of
    /// metres is the accuracy that costs the least battery while still naming
    /// the right neighbourhood.
    private static let accuracy = kCLLocationAccuracyHundredMeters

    /// A fix older than this is a place the phone used to be. Better to write
    /// no coordinate than the wrong one.
    private static let maximumAge: TimeInterval = 5 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = LocationTagger.accuracy
    }

    /// Asked for alongside the camera, and only ever while in use: the app has
    /// no reason to know where the phone is when it isn't being pointed at
    /// something.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// The GPS block for the frame being written, or nothing when there is no
    /// recent fix — a missing coordinate is simply a line the develop screen
    /// leaves out.
    var gpsProperties: [String: Any]? {
        lock.lock()
        let location = latest
        lock.unlock()

        guard let location,
              location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(location.timestamp) < LocationTagger.maximumAge else {
            return nil
        }
        return LocationTagger.properties(for: location)
    }

    /// EXIF keeps the hemisphere apart from the number, so each coordinate goes
    /// in twice: its size, and which way it points.
    static func properties(for location: CLLocation) -> [String: Any] {
        let coordinate = location.coordinate

        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSTimeStamp as String: timeFormatter.string(from: location.timestamp),
            kCGImagePropertyGPSDateStamp as String: dateFormatter.string(from: location.timestamp),
        ]

        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        }

        return gps
    }

    /// Both stamps are UTC by definition of the tag, whatever the phone's clock
    /// is showing.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lock.lock()
        latest = location
        lock.unlock()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            manager.stopUpdatingLocation()
            lock.lock()
            latest = nil
            lock.unlock()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: the last good fix stands until it goes stale, and a
        // frame written without a coordinate is a frame with one line less.
    }
}
