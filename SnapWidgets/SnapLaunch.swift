//
//  SnapLaunch.swift
//  SnapWidgets
//
//  The URL both lock-screen entries carry into the app: the widget as its
//  `widgetURL`, the control as the URL its button opens.
//
//  An app that is merely launched cannot tell whether it was launched from a
//  pocket or resumed from the switcher, and those two want opposite things.
//  Coming back to the app means coming back to what you were doing; arriving
//  from the lock screen means arriving at the camera, ready. The URL is what
//  says which happened — an intent performed out here in the extension has no
//  way to reach into the app and tell it.
//
//  `LaunchRoute` in the app target holds the other half of this. Two targets,
//  one string, changed together: the extension cannot see the app's files.
//

import Foundation

enum SnapLaunch {
    static let url = URL(string: "snapsquarecamera://capture")!
}
