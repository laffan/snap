//
//  ShotGrid.swift
//  Snap
//
//  The whole roll as a wall of squares. Reached by holding the four filled
//  squares at the right of the action bar, which are already a picture of a
//  grid.
//
//  The strip along the bottom edge is the roll as a line you walk; this is the
//  roll as a page you scan. Same store, same frames, the same marks in the same
//  corners — what it adds is the one thing a line of thumbnails under a live
//  preview has no room for: several frames ticked at once, and shared or
//  deleted together.
//
//  Built the way the snapshots are, since it is the same shape of screen and
//  the two should not read as two ideas. What it doesn't borrow is Clear:
//  emptying a wall of accidents is housekeeping, and emptying a roll of
//  photographs is not something to put one tap away.
//

import SwiftUI

struct ShotGrid: View {

    @ObservedObject var store: ShotStore

    /// Opens one frame in the viewer, which is what closes the grid.
    var onSelect: (Shot) -> Void
    var onToggleFavorite: (Shot) -> Void
    var onDelete: (Shot) -> Void
    /// Several at once, so the camera roll is asked once rather than once a
    /// frame.
    var onDeleteAll: ([Shot]) -> Void
    var onClose: () -> Void

    /// The share sheet is put up from here rather than handed back to the
    /// camera screen: this grid is itself a sheet, and a screen that is covered
    /// cannot present anything over the thing covering it.
    @State private var share: ShareItem? = nil
    /// Picking a few out of the wall. Nil while simply looking.
    @State private var selection: Set<UUID>? = nil
    @State private var isConfirmingDelete = false

    /// Three across, and 3pt of black between, the same wall the snapshots
    /// are laid on.
    private static let columns = 3
    private static let spacing: CGFloat = 3

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of CameraView.
    init(store: ShotStore,
         onSelect: @escaping (Shot) -> Void,
         onToggleFavorite: @escaping (Shot) -> Void,
         onDelete: @escaping (Shot) -> Void,
         onDeleteAll: @escaping ([Shot]) -> Void,
         onClose: @escaping () -> Void) {
        self.store = store
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onDeleteAll = onDeleteAll
        self.onClose = onClose
    }

    private var isSelecting: Bool { selection != nil }

    private var selected: [Shot] {
        guard let selection else { return [] }
        return store.shots.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.shots.isEmpty {
                    ContentUnavailableView(
                        "No Frames",
                        systemImage: "square.grid.2x2",
                        description: Text("Every photograph Snap takes lands in the roll.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { leadingItem; trailingItem }
            .confirmationDialog(deletePrompt,
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
            }
            .sheet(item: $share) { ShareSheet(urls: $0.urls) }
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        guard let selection else { return "Roll" }
        return selection.isEmpty ? "Select" : "\(selection.count) Selected"
    }

    /// Says how many are about to go, since the wall is the one place in the
    /// app where a tap can take more than one photograph with it.
    private var deletePrompt: String {
        let count = selected.count
        return count == 1 ? "Delete this frame?" : "Delete these \(count) frames?"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var leadingItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isSelecting {
                Button("Cancel") { selection = nil }
            } else if !store.shots.isEmpty {
                Button("Select") { selection = [] }
            }
        }
    }

    @ToolbarContentBuilder
    private var trailingItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if isSelecting {
                HStack(spacing: 18) {
                    Button {
                        share = ShareItem(selected.map { store.imageURL(for: $0) })
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(selected.isEmpty)

                    Button(role: .destructive) {
                        isConfirmingDelete = true
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
        let doomed = selected
        guard !doomed.isEmpty else { return }
        onDeleteAll(doomed)
        // Stays in select mode with nothing ticked: clearing out is usually
        // more than one pass, and being dropped back to plain looking after
        // each one would mean starting again. The store has already reloaded
        // by here — the delete and its publish both happen on this thread.
        selection = store.shots.isEmpty ? nil : []
    }

    // MARK: - The wall

    private var grid: some View {
        GeometryReader { geometry in
            let spacing = ShotGrid.spacing
            let count = ShotGrid.columns
            let edge = ((geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                .rounded(.down)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(edge), spacing: spacing),
                                         count: count),
                          spacing: spacing) {
                    ForEach(store.shots) { shot in
                        cell(shot, edge: edge)
                    }
                }
                .padding(.vertical, spacing)
                .animation(.easeOut(duration: 0.2), value: store.shots.count)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func cell(_ shot: Shot, edge: CGFloat) -> some View {
        let isPicked = selection?.contains(shot.id) == true

        return ShotThumbnail(store: store, shot: shot, edge: edge, cornerRadius: 3)
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
            // The same pair of taps every other wall of frames answers to: two
            // to keep a frame, one to do whatever the screen is for. Said as an
            // exclusive pair so the single tap waits for the double to fail —
            // see `FavoritesList`, where letting SwiftUI choose meant the
            // double could never land.
            .gesture(
                TapGesture(count: 2)
                    .onEnded { onToggleFavorite(shot) }
                    .exclusively(before: TapGesture().onEnded { tap(shot) })
            )
            .contextMenu {
                Button {
                    onToggleFavorite(shot)
                } label: {
                    Label(shot.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: shot.isFavorite ? "heart.slash" : "heart")
                }

                Button {
                    share = ShareItem([store.imageURL(for: shot)])
                } label: {
                    Label("Share JPEG", systemImage: "square.and.arrow.up")
                }

                if !store.negativeURLs(for: shot).isEmpty {
                    Button {
                        share = ShareItem(store.negativeURLs(for: shot))
                    } label: {
                        Label("Share RAW", systemImage: "square.and.arrow.up.on.square")
                    }
                }

                Button(role: .destructive) {
                    onDelete(shot)
                } label: {
                    Label("Delete Image", systemImage: "trash")
                }
            }
    }

    private func tap(_ shot: Shot) {
        guard var picked = selection else {
            onSelect(shot)
            return
        }
        if picked.contains(shot.id) {
            picked.remove(shot.id)
        } else {
            picked.insert(shot.id)
        }
        selection = picked
    }
}
