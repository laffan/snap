//
//  Shot.swift
//  Snap
//
//  One photograph the app has taken, and the look that made it.
//

import Foundation

struct Shot: Codable, Identifiable, Equatable {
    var id: UUID
    /// Empty until the shot is named. The strip and the load list fall back to
    /// the timestamp.
    var title: String
    var notes: String
    var createdAt: Date
    /// File name of the frame, relative to the store's directory.
    var imageFileName: String
    var profile: PositiveFilmProfile

    init(id: UUID = UUID(),
         title: String = "",
         notes: String = "",
         createdAt: Date = Date(),
         imageFileName: String,
         profile: PositiveFilmProfile) {
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = createdAt
        self.imageFileName = imageFileName
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
