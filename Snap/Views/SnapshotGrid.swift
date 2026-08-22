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
//  They still carry when and where, written into each file on the way out, so
//  one opened large can say what it is.
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
    /// Picking a few out of the wall. Nil while simply looking.
    @State private var selection: Set<UUID>? = nil

    /// Three across, and 3pt of black between, exactly as the favourites were
    /// before they became a list.
    private static let columns = 3
    private static let spacing: CGFloat = 3

    private var isSelecting: Bool { selection != nil }

    private var selected: [Snapshot] {
        guard let selection else { return [] }
        return store.snapshots.filter { selection.contains($0.id) }
    }

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
                    SnapshotDetail(snapshot: showing) {
                        withAnimation(.easeOut(duration: 0.18)) { self.showing = nil }
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { leadingItem; trailingItem }
            .confirmationDialog("Delete every snapshot?",
                                isPresented: $isConfirmingClear,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    store.deleteAll()
                    selection = nil
                }
            }
            .sheet(item: $share) { ShareSheet(urls: $0.urls) }
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        guard let selection else { return "Snapshots" }
        return selection.isEmpty ? "Select" : "\(selection.count) Selected"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var leadingItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isSelecting {
                Button("Cancel") { selection = nil }
            } else if !store.snapshots.isEmpty {
                Menu {
                    Button {
                        selection = []
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }

                    Button {
                        share = ShareItem(store.snapshots.map(\.url))
                    } label: {
                        Label("Export All", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Snapshot actions")
            }
        }
    }

    @ToolbarContentBuilder
    private var trailingItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if isSelecting {
                HStack(spacing: 18) {
                    Button {
                        share = ShareItem(selected.map(\.url))
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(selected.isEmpty)

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selected.isEmpty)
                }
            } else {
                Button("Done", action: onClose)
            }
        }
    }

    private func deleteSelected() {
        for snapshot in selected {
            if showing == snapshot { showing = nil }
            store.delete(snapshot)
        }
        selection = store.snapshots.isEmpty ? nil : []
    }

    // MARK: - The wall

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
                        cell(snapshot, edge: edge)
                    }
                }
                .padding(.vertical, spacing)
                .animation(.easeOut(duration: 0.2), value: store.snapshots.count)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func cell(_ snapshot: Snapshot, edge: CGFloat) -> some View {
        let isPicked = selection?.contains(snapshot.id) == true

        return SnapshotThumbnail(url: snapshot.url, edge: edge)
            .opacity(isSelecting && !isPicked ? 0.45 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isPicked ? Color.snapAccent : .white.opacity(0.7))
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .padding(5)
                }
            }
            .onTapGesture {
                if isSelecting {
                    toggle(snapshot)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { showing = snapshot }
                }
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

    private func toggle(_ snapshot: Snapshot) {
        guard var picked = selection else { return }
        if picked.contains(snapshot.id) {
            picked.remove(snapshot.id)
        } else {
            picked.insert(snapshot.id)
        }
        selection = picked
    }
}

// MARK: - One frame, whole

/// A snapshot at full width, with when and where it was left behind under it.
///
/// Both readings come out of the file, the same way the develop screen and the
/// favourites read theirs — a snapshot is stamped with the moment and the
/// coordinate on its way out, since it is a photograph of somewhere at some
/// time like any other.
private struct SnapshotDetail: View {

    let snapshot: Snapshot
    var onDismiss: () -> Void

    @State private var info = ShotInfo()
    @State private var place: String? = nil

    private static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                SnapshotThumbnail(url: snapshot.url, edge: nil, cornerRadius: 0)
                    .aspectRatio(1, contentMode: .fit)

                VStack(spacing: 3) {
                    Text(info.dateLabel ?? SnapshotDetail.fallbackFormatter.string(from: snapshot.date))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))

                    if let place = place ?? info.coordinateLabel {
                        Text(place)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .task(id: snapshot.id) {
            let url = snapshot.url
            let fallback = snapshot.date
            info = await Task.detached(priority: .userInitiated) {
                ShotInfo.read(at: url, fallbackDate: fallback)
            }.value

            guard let coordinate = info.coordinate else { return }
            place = await PlaceNames.shared.name(latitude: coordinate.latitude,
                                                 longitude: coordinate.longitude)
        }
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
