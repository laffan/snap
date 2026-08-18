//
//  ShareSheet.swift
//  Snap
//

import SwiftUI
import UIKit

/// Hands a file — a single photo, or a whole bundle — to the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `sheet(item:)` needs something Identifiable, and a bare URL isn't.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
