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
//  It is also where the backup lives, because the backup is about these frames
//  and no others: the menu at the top left is where a folder is chosen, and
//  each row says underneath its caption what that folder has of it.
//

import SwiftUI
import UniformTypeIdentifiers

struct FavoritesList: View {

    @ObservedObject var store: ShotStore
    @ObservedObject var backup: FavoritesBackup

    /// Opens the frame in the viewer, which is what the list is a way into.
    var onSelect: (Shot) -> Void
    var onToggleFavorite: (Shot) -> Void
    var onCommitCaption: (Shot, String) -> Void
    var onClose: () -> Void

    /// True while the system folder picker is up.
    @State private var isPickingFolder = false

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of CameraView —
    // the same reason the grid and the strip have one.
    init(store: ShotStore,
         backup: FavoritesBackup,
         onSelect: @escaping (Shot) -> Void,
         onToggleFavorite: @escaping (Shot) -> Void,
         onCommitCaption: @escaping (Shot, String) -> Void,
         onClose: @escaping () -> Void) {
        self.store = store
        self.backup = backup
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onCommitCaption = onCommitCaption
        self.onClose = onClose
    }

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
            .navigationTitle(backup.isCopying ? "Backing Up…" : "Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { backupMenu }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
            // A folder rather than files: the app is not picking anything to
            // read, it is being told where to put things. Everything after
            // this is a bookmark to that one directory.
            .fileImporter(isPresented: $isPickingFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                backup.folderChosen(url)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { backup.paneOpened() }
    }

    // MARK: - The backup menu

    /// Where the folder is chosen, changed, and given up.
    ///
    /// A menu rather than a row of buttons, and at the top left rather than
    /// beside Done, because none of it is about the list you are looking at —
    /// it is about where that list goes, which is asked once and then left
    /// alone. It is the same corner and the same glyph the snapshots put their
    /// own three collection-wide actions in.
    private var backupMenu: some View {
        Menu {
            if let folderName = backup.folderName {
                Section("Backing up to \(folderName)") {
                    Button {
                        backup.checkNow()
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.clockwise")
                    }

                    Button {
                        isPickingFolder = true
                    } label: {
                        Label("Change Folder", systemImage: "folder")
                    }

                    Button(role: .destructive) {
                        backup.stop()
                    } label: {
                        Label("Stop Backing Up", systemImage: "folder.badge.minus")
                    }
                }
            } else {
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Set Backup Folder", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Backup")
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.favorites) { shot in
                    FavoriteRow(store: store,
                                backup: backup,
                                shot: shot,
                                onSelect: { onSelect(shot) },
                                onToggleFavorite: { onToggleFavorite(shot) },
                                onCommitCaption: { onCommitCaption(shot, $0) },
                                onResend: { backup.resend(shot) })

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
    @ObservedObject var backup: FavoritesBackup
    let shot: Shot

    var onSelect: () -> Void
    var onToggleFavorite: () -> Void
    var onCommitCaption: (String) -> Void
    var onResend: () -> Void

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
                .gesture(doubleThenSingle(double: onToggleFavorite, single: onSelect))

            VStack(alignment: .leading, spacing: 3) {
                if let date = info.dateLabel {
                    line(date, emphasis: true)
                }
                if let placeLabel {
                    line(placeLabel, emphasis: false)
                }
                caption
                BackupStatusLine(state: backup.state(for: shot),
                                 onResend: onResend,
                                 onRemove: onToggleFavorite)
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
                    // Asked for here rather than in the tap that opened the
                    // field: focus given to a field that isn't on screen yet
                    // lands nowhere, and this is the first moment it is.
                    .onAppear { isFocused = true }
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
                .gesture(doubleThenSingle(double: beginEditing, single: onSelect))
                .accessibilityHint("Double-tap to edit the caption")
        }
    }

    /// Two taps beat one, deterministically.
    ///
    /// Attaching `.onTapGesture(count: 2)` and `.onTapGesture()` to the same
    /// view leaves which of them wins up to SwiftUI, and in a scrolling list it
    /// picks the single tap — which here meant the row opened the frame before
    /// the second tap ever landed, and the caption could never be edited. Said
    /// as an exclusive pair, the single tap only fires once the double has
    /// failed, which is the arrangement this always meant.
    private func doubleThenSingle(double: @escaping () -> Void,
                                  single: @escaping () -> Void) -> some Gesture {
        TapGesture(count: 2)
            .onEnded { double() }
            .exclusively(before: TapGesture().onEnded { single() })
    }

    private func beginEditing() {
        draft = shot.caption
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
