//
//  Preset.swift
//  Snap
//
//  A saved moment: the look, the frame it produced, and what you called it.
//

import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var createdAt: Date
    /// File name of the frame captured alongside these settings, relative to
    /// the store's directory.
    var imageFileName: String
    var profile: PositiveFilmProfile

    init(id: UUID = UUID(),
         title: String,
         notes: String,
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

    /// The title offered when the user hasn't typed one.
    static func defaultTitle(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
