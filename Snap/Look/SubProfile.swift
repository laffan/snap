//
//  SubProfile.swift
//  Snap
//
//  Small named corrections that sit on top of the look rather than inside it.
//
//  The base profile is one thing being developed slowly and carefully; the
//  rooms a photograph is actually taken in are another. Warm indoor light comes
//  out yellow through a profile built in daylight, and a dark room comes out
//  grainy through a curve built to open shadows. Rather than move the base
//  every time the light changes, a sub-profile lays a few settings over the top
//  of it and can be switched off again with the same tap.
//
//  Nothing here edits the base. A sub-profile takes over the settings it names
//  and leaves everything else alone, which is why the sliders in the develop
//  panel go on showing the base values while one is lit: they are still what is
//  being worked on.
//

import Foundation

enum SubProfile: String, Codable, CaseIterable, Identifiable {

    /// Warm indoor light, cooled back toward neutral.
    case indoor
    /// A dark room, where the shadows are mostly sensor noise.
    case night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .indoor: return "Indoor"
        case .night:  return "Night"
        }
    }

    /// A house and a moon, above the shutter and again beside the shutter speed
    /// of a frame that was taken with one lit.
    var symbol: String {
        switch self {
        case .indoor: return "house"
        case .night:  return "moon"
        }
    }

    /// Lays this sub-profile over a profile.
    ///
    /// The settings named here are set rather than nudged: a toggle should mean
    /// the same thing wherever the base happens to be sitting, and switching it
    /// off puts the base back untouched. Two lit at once apply in the order of
    /// `allCases`, so they read down the row the way they sit in it.
    func applied(to profile: PositiveFilmProfile) -> PositiveFilmProfile {
        var result = profile
        switch self {
        case .indoor:
            // Enough to take the yellow off a lamp-lit room without turning it
            // into daylight, which it isn't.
            result.temperature = -20
        case .night:
            // Down the exposure and close the shadows rather than open them:
            // what is in the shadows of a dark frame is mostly noise, and the
            // base profile is built to lift it.
            result.exposure = -0.6
            result.shadows = -40
        }
        return result
    }
}
