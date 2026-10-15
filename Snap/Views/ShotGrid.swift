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
    /// The list of days, opened from the title while picking.
    @State private var isPickingDay = false
    /// The frame the wall should bring into view, once. Cleared as soon as it
    /// has, so picking the same day twice scrolls twice.
    @State private var scrollTarget: UUID? = nil

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
            .toolbar { leadingItem; titleMenu; trailingItem }
            .confirmationDialog(deletePrompt,
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
            }
            .sheet(item: $share) { ShareSheet(urls: $0.urls) }
            .sheet(isPresented: $isPickingDay) {
                DayList(days: days) { day in
                    isPickingDay = false
                    select(day: day.date)
                }
            }
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

    /// While picking, the title is also how to pick in bulk: tap it for the
    /// whole wall, today's frames, or none. It sits where the count it
    /// changes is already written, and a dropdown keeps the bar to the two
    /// things that act on what is ticked.
    @ToolbarContentBuilder
    private var titleMenu: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button {
                        selection = Set(store.shots.map(\.id))
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }

                    Button {
                        select(day: .now)
                    } label: {
                        Label("Select Today's", systemImage: "sun.max")
                    }

                    Button {
                        isPickingDay = true
                    } label: {
                        Label("Select Date…", systemImage: "calendar")
                    }

                    Button {
                        selection = []
                    } label: {
                        Label("Deselect All", systemImage: "circle")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                .accessibilityLabel(title)
                .accessibilityHint("Select all, today's, a date, or none")
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

    // MARK: - Days

    /// One calendar day of the roll: when, and how many frames it holds.
    struct Day: Identifiable {
        var date: Date
        var count: Int
        var id: Date { date }
    }

    /// Every day with something on it, newest first — the order the wall
    /// runs in, so the list reads the same way down as the frames do.
    private var days: [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for shot in store.shots {
            let day = calendar.startOfDay(for: shot.createdAt)
            if let last = result.last, last.date == day {
                result[result.count - 1].count += 1
            } else if let index = result.firstIndex(where: { $0.date == day }) {
                // The roll is newest first, so this only happens for a frame
                // whose clock disagreed with its neighbours'.
                result[index].count += 1
            } else {
                result.append(Day(date: day, count: 1))
            }
        }
        return result
    }

    /// Ticks exactly the frames taken on the day `date` falls in, in place of
    /// whatever was ticked, and brings the first of them into view: a day
    /// picked out of a list is a day you want to look at, and it may be a
    /// long way down the wall.
    private func select(day date: Date) {
        let calendar = Calendar.current
        let picked = store.shots.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
        selection = Set(picked.map(\.id))
        scrollTarget = picked.first?.id
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(edge), spacing: spacing),
                                             count: count),
                              spacing: spacing) {
                        ForEach(store.shots) { shot in
                            cell(shot, edge: edge)
                                .id(shot.id)
                        }
                    }
                    .padding(.vertical, spacing)
                    .animation(.easeOut(duration: 0.2), value: store.shots.count)
                }
                .scrollIndicators(.hidden)
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
                }
            }
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

/// The roll as a list of days, for ticking one of them on the wall.
///
/// A count beside each, since the question is usually *which afternoon was
/// that* and the size of a day is half of how you remember it.
private struct DayList: View {

    var days: [ShotGrid.Day]
    var onPick: (ShotGrid.Day) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(days) { day in
                Button {
                    onPick(day)
                } label: {
                    HStack {
                        Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(day.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                .accessibilityValue(day.count == 1 ? "1 frame" : "\(day.count) frames")
            }
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
