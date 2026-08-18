//
//  ShareSheet.swift
//  Snap
//

import SwiftUI
import UIKit

/// Hands a finished bundle to the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `sheet(item:)` needs something Identifiable, and a bare URL isn't.
struct BundleFile: Identifiable {
    let id = UUID()
    let url: URL
}
