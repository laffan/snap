//
//  ShareSheet.swift
//  Snap
//

import SwiftUI
import UIKit

/// Hands one or more files — a photo, a negative and its sidecar, or a whole
/// bundle — to the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {

    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `sheet(item:)` needs something Identifiable, and a bare URL isn't.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]

    init(_ urls: [URL]) {
        self.urls = urls
    }
}
