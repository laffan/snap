//
//  FavoritesGrid.swift
//  Snap
//
//  The kept frames, as a grid. Reached by the heart beside Develop, and beside
//  the develop panel's own menu.
//
//  A second window onto the same roll rather than a second roll: nothing lives
//  here that isn't in the store, and a frame leaves by being double-tapped
//  again, in the grid or anywhere else.
//

import SwiftUI

struct FavoritesGrid: View {

    @ObservedObject var store: ShotStore

    /// Opens the frame in the viewer, which is what the grid is a way into.
    var onSelect: (Shot) -> Void
    var onToggleFavorite: (Shot) -> Void
    var onClose: () -> Void

    /// Three across is the arrangement a square roll wants, and 3pt of black
    /// between frames is enough to separate two that end on the same tone.
    private static let columns = 3
    private static let spacing: CGFloat = 3

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.favorites.isEmpty {
                    ContentUnavailableView("No Favorites",
                                           systemImage: "heart",
                                           description: Text("Double-tap a frame to keep it here."))
                } else {
                    grid
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let spacing = FavoritesGrid.spacing
            let count = FavoritesGrid.columns
            let edge = ((geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                .rounded(.down)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(edge), spacing: spacing),
                                         count: count),
                          spacing: spacing) {
                    ForEach(store.favorites) { shot in
                        ShotThumbnail(store: store, shot: shot, edge: edge, cornerRadius: 3)
                            // Same pair of taps as the roll: two to let a frame
                            // go, one to open it.
                            .onTapGesture(count: 2) { onToggleFavorite(shot) }
                            .onTapGesture { onSelect(shot) }
                    }
                }
                .padding(.vertical, spacing)
                .animation(.easeOut(duration: 0.2), value: store.favorites.count)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The way into the grid: a heart beside Develop on the camera screen, and
/// beside the panel's menu once the panel is open.
///
/// Watches the roll itself rather than being told what is in it, so that a
/// frame kept or let go anywhere in the app lights or dims this in the same
/// breath. Out while nothing is kept, the same way Develop goes out when there
/// is nothing to develop — an empty grid isn't worth a screen.
struct FavoritesButton: View {

    @ObservedObject var store: ShotStore
    var action: () -> Void

    /// Known here so the camera screen can leave a gap of the same width on
    /// the other side of Develop and keep it centred under the shutter.
    static let width: CGFloat = 32

    private var isEnabled: Bool { !store.favorites.isEmpty }

    var body: some View {
        Button(action: action) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: FavoritesButton.width, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel("Favorites")
    }
}
