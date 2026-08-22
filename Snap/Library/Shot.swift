//
//  Shot.swift
//  Snap
//
//  One photograph the app has taken, and the look that made it.
//

import Foundation

struct Shot: Codable, Identifiable, Equatable {

    /// How the frame came about. The strip marks the two that didn't come from
    /// an ordinary shutter press.
    enum Origin: String, Codable {
        /// The shutter button.
        case camera
        /// PS — the preview frame itself, saved as it stood.
        case preview
        /// Made in the develop screen: a re-developed negative, or a capture
        /// taken from the panel's own menu. Still written as "filter": the
        /// screen was called that when the first sidecars were written, and
        /// those sidecars still have to load.
        case develop = "filter"
    }

    var id: UUID
    /// Empty until the shot is named. The strip and the load list fall back to
    /// the timestamp.
    var title: String
    /// The caption, written into the frame's own EXIF as well as into this
    /// sidecar. Entered on the review screen under the frame, or in the naming
    /// sheet a titled capture ends at — one line of text per photograph,
    /// reachable two ways.
    var caption: String
    var createdAt: Date
    /// File name of the frame, relative to the store's directory.
    var imageFileName: String
    /// File name of the negative, when the capture was RAW. Optional so shots
    /// saved before RAW existed still decode.
    var rawFileName: String?
    /// File name of the Camera Raw sidecar that travels with the negative.
    var xmpFileName: String?
    var origin: Origin
    /// Kept by a double tap, and the only thing the favourites grid reads.
    var isFavorite: Bool
    /// The camera roll's own name for this frame, kept so deleting it here can
    /// delete it there. Nil for a shot the library refused, and for every shot
    /// taken before the app started asking.
    var assetIdentifier: String?
    var profile: PositiveFilmProfile

    init(id: UUID = UUID(),
         title: String = "",
         caption: String = "",
         createdAt: Date = Date(),
         imageFileName: String,
         rawFileName: String? = nil,
         xmpFileName: String? = nil,
         origin: Origin = .camera,
         isFavorite: Bool = false,
         assetIdentifier: String? = nil,
         profile: PositiveFilmProfile) {
        self.id = id
        self.title = title
        self.caption = caption
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.rawFileName = rawFileName
        self.xmpFileName = xmpFileName
        self.origin = origin
        self.isFavorite = isFavorite
        self.assetIdentifier = assetIdentifier
        self.profile = profile
    }

    /// What to show when the shot hasn't been given a name.
    var displayTitle: String {
        title.isEmpty ? Shot.timestamp(for: createdAt) : title
    }

    static func timestamp(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Lenient decoding

/// Hand-written for the same reason the profile's is: a sidecar written before
/// `origin` existed still has to load, and a synthesised decode would throw on
/// the missing key and take the shot with it. Those shots read as ordinary
/// captures.
///
/// In an extension so the memberwise initialiser above survives.
extension Shot {

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt
        // Written as "notes", which is what this field was called before it
        // became the caption. The sidecars already on disk still have to load.
        case caption = "notes"
        case imageFileName, rawFileName, xmpFileName
        case origin, isFavorite, assetIdentifier, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  title: try container.decode(String.self, forKey: .title),
                  caption: try container.decode(String.self, forKey: .caption),
                  createdAt: try container.decode(Date.self, forKey: .createdAt),
                  imageFileName: try container.decode(String.self, forKey: .imageFileName),
                  rawFileName: try container.decodeIfPresent(String.self, forKey: .rawFileName),
                  xmpFileName: try container.decodeIfPresent(String.self, forKey: .xmpFileName),
                  origin: ((try? container.decodeIfPresent(Origin.self, forKey: .origin)) ?? nil) ?? .camera,
                  isFavorite: ((try? container.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? nil) ?? false,
                  assetIdentifier: try container.decodeIfPresent(String.self, forKey: .assetIdentifier),
                  profile: try container.decode(PositiveFilmProfile.self, forKey: .profile))
    }
}
