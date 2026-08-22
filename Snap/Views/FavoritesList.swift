//
//  FavoritesList.swift
//  Snap
//
//  The kept frames, one to a row. Reached by the heart on the action bar.
//
//  A list rather than a grid: a wall of squares is a good way to find a
//  photograph you can already picture, and a poor way to read a roll. Each row
//  says when the frame was taken, where, and what was written about it — and
//  the caption can be written here, since this is where you end up reading
//  them.
//
//  A second window onto the same roll rather than a second roll: nothing lives
//  here that isn't in the store, and a frame leaves by being double-tapped
//  again, here or anywhere else.
//

import SwiftUI

struct FavoritesList: View {

    @ObservedObject var store: ShotStore

    /// Opens the frame in the viewer, which is what the list is a way into.
    var onSelect: (Shot) -> Void
    var onToggleFavorite: (Shot) -> Void
    var onCommitCaption: (Shot, String) -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.favorites.isEmpty {
                    ContentUnavailableView("No Favorites",
                                           systemImage: "heart",
                                           description: Text("Double-tap a frame to keep it here."))
                } else {
                    rows
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

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.favorites) { shot in
                    FavoriteRow(store: store,
                                shot: shot,
                                onSelect: { onSelect(shot) },
                                onToggleFavorite: { onToggleFavorite(shot) },
                                onCommitCaption: { onCommitCaption(shot, $0) })

                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.favorites.count)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - A row

/// One kept frame: the square on the left, what it is on the right.
private struct FavoriteRow: View {

    @ObservedObject var store: ShotStore
    let shot: Shot

    var onSelect: () -> Void
    var onToggleFavorite: () -> Void
    var onCommitCaption: (String) -> Void

    @State private var info = ShotInfo()
    @State private var place: String? = nil
    /// Non-nil while the caption is being written. Holding the draft apart from
    /// the shot is what lets Cancel mean cancel.
    @State private var draft: String? = nil
    @FocusState private var isFocused: Bool

    private static let thumbnailEdge: CGFloat = 62

    private var placeLabel: String? {
        place ?? info.coordinateLabel
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draft ?? "" }, set: { draft = $0 })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShotThumbnail(store: store, shot: shot, edge: FavoriteRow.thumbnailEdge)
                // The same pair of taps the roll answers to: two to let a frame
                // go, one to open it.
                .onTapGesture(count: 2) { onToggleFavorite() }
                .onTapGesture { onSelect() }

            VStack(alignment: .leading, spacing: 3) {
                if let date = info.dateLabel {
                    line(date, emphasis: true)
                }
                if let placeLabel {
                    line(placeLabel, emphasis: false)
                }
                caption
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: shot.id) { await load() }
    }

    private func line(_ text: String, emphasis: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: emphasis ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(emphasis ? 0.85 : 0.5))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The caption, and the field it becomes.
    ///
    /// Double-tapped rather than tapped, so that a single tap anywhere on the
    /// row still means open the frame — the same division the roll makes
    /// between a tap and a double tap.
    @ViewBuilder
    private var caption: some View {
        if draft != nil {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Caption", text: draftBinding, axis: .vertical)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .tint(Color.snapAccent)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .focused($isFocused)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.28))
                            .frame(height: 0.5)
                    }

                HStack(spacing: 16) {
                    Button("Cancel") { endEditing() }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))

                    Button("Save") { save() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.snapAccent)
                }
            }
            .padding(.top, 2)
        } else {
            Text(shot.caption.isEmpty ? "Add a caption" : shot.caption)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(shot.caption.isEmpty ? 0.28 : 0.7))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEditing() }
                .onTapGesture { onSelect() }
                .accessibilityHint("Double-tap to edit the caption")
        }
    }

    private func beginEditing() {
        draft = shot.caption
        isFocused = true
    }

    private func endEditing() {
        isFocused = false
        draft = nil
    }

    private func save() {
        onCommitCaption((draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        endEditing()
    }

    /// The same two readings the develop screen shows, from the same place: the
    /// file itself, and the geocoder for the name of somewhere.
    private func load() async {
        place = nil

        let url = store.imageURL(for: shot)
        let date = shot.createdAt
        let read = await Task.detached(priority: .userInitiated) {
            ShotInfo.read(at: url, fallbackDate: date)
        }.value

        info = read

        guard let coordinate = read.coordinate else { return }
        place = await PlaceNames.shared.name(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude)
    }
}

// MARK: - The way in

/// The heart on the action bar.
///
/// Watches the roll itself rather than being told what is in it, so that a
/// frame kept or let go anywhere in the app lights or dims this in the same
/// breath. Out while nothing is kept, the same way Develop goes out when there
/// is nothing to develop — an empty list isn't worth a screen.
struct FavoritesButton: View {

    @ObservedObject var store: ShotStore
    var action: () -> Void

    /// A tap target rather than a glyph: the heart is 12 points across and
    /// nobody's finger is.
    private static let side: CGFloat = 32

    private var isEnabled: Bool { !store.favorites.isEmpty }

    var body: some View {
        Button(action: action) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: FavoritesButton.side, height: FavoritesButton.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel("Favorites")
    }
}
