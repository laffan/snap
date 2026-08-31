//
//  Palette.swift
//  Snap
//

import SwiftUI

extension Color {
    /// The one colour in an otherwise black-and-white interface. Reserved for
    /// state that is switched on, so it always means the same thing.
    static let snapAccent = Color(red: 1.0, green: 0.82, blue: 0.25)

    /// Reset, once the look has moved off the one the app ships with.
    ///
    /// The second colour, and it is spent on the one button that undoes
    /// everything: red is what says *this will throw work away*, and it is only
    /// there while there is work to throw away.
    static let snapReset = Color(red: 1.0, green: 0.35, blue: 0.32)

    /// The border around the frame while the loupe is up.
    ///
    /// Light blue rather than the accent: the accent means a setting is
    /// switched on, and the loupe changes nothing about the photograph — it is
    /// a way of looking at one, and it gets a colour of its own so the two
    /// never read as the same thing.
    static let snapLoupe = Color(red: 0.45, green: 0.76, blue: 1.0)
}
