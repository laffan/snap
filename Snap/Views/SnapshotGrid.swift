//
//  SnapshotGrid.swift
//  Snap
//
//  The frames the app left behind, as a grid. Reached by the starburst at the
//  right of the action bar.
//
//  A grid rather than a list, unlike the favourites: nobody wrote a caption on
//  one of these and nothing about them was chosen, so there is nothing to read
//  down a column. What they have is a picture, and the picture is the whole
//  point — a wall of accidents is the right way to look at them.
//

import SwiftUI
import UIKit

struct SnapshotGrid: View {

    @ObservedObject var store: SnapshotStore
    var onClose: () -> Void

    /// The one being looked at large, if any.
    @State private var showing: Snapshot? = nil
    @State private var share: ShareItem? = nil
    @State private var isConfirmingClear = false

    /// Three across, and 3pt of black between, exactly as the favourites were
    /// before they became a list.
    private static let columns = 3
    private static let spacing: CGFloat = 3

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.snapshots.isEmpty {
                    ContentUnavailableView(
                        "No Snapshots",
                        systemImage: "sparkle",
                        description: Text("Leave the app with the preview up and the frame it freezes on is kept here.")
                    )
                } else {
                    grid
                }

                if let showing {
                    enlarged(showing)
                }
            }
            .navigationTitle("Snapshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !store.snapshots.isEmpty {
                        Button("Clear", role: .destructive) { isConfirmingClear = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
            .confirmationDialog("Delete every snapshot?",
                                isPresented: $isConfirmingClear,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.deleteAll() }
            }
            .sheet(item: $share) { ShareSheet(urls: $0.urls) }
        }
        .preferredColorScheme(.dark)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let spacing = SnapshotGrid.spacing
            let count = SnapshotGrid.columns
            let edge = ((geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                .rounded(.down)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(edge), spacing: spacing),
                                         count: count),
                          spacing: spacing) {
                    ForEach(store.snapshots) { snapshot in
                        SnapshotThumbnail(url: snapshot.url, edge: edge)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.18)) { showing = snapshot }
                            }
                            .contextMenu {
                                Button {
                                    share = ShareItem([snapshot.url])
                                } label: {
                                    Label("Share JPEG", systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    if showing == snapshot { showing = nil }
                                    store.delete(snapshot)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, spacing)
                .animation(.easeOut(duration: 0.2), value: store.snapshots.count)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// One frame, filling the width, with the moment it was left behind under
    /// it. Tapping anywhere puts it down again.
    private func enlarged(_ snapshot: Snapshot) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                SnapshotThumbnail(url: snapshot.url, edge: nil, cornerRadius: 0)
                    .aspectRatio(1, contentMode: .fit)

                Text(SnapshotGrid.dateFormatter.string(from: snapshot.date))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { showing = nil }
        }
        .transition(.opacity)
    }
}

// MARK: - One frame

/// A snapshot as a square, decoded down to the size it is being shown at.
///
/// `edge` is nil when it should take whatever width it is given, which is what
/// the enlarged view wants.
private struct SnapshotThumbnail: View {

    let url: URL
    let edge: CGFloat?
    var cornerRadius: CGFloat = 3

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.07)
            }
        }
        .frame(width: edge, height: edge)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url) {
            guard image == nil else { return }
            // The app's one downsampler, wherever a file has to become a
            // thumbnail. 3x covers the densest screen there is; a snapshot is
            // a preview frame to begin with, so the whole of one is never much
            // more than 1600 across.
            let pixels = edge.map { $0 * 3 } ?? 1600
            image = await Task.detached(priority: .userInitiated) {
                ShotStore.image(at: url, maxPixelSize: pixels)
            }.value
        }
    }
}
