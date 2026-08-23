//
//  FilmStrip.swift
//  Snap
//
//  The app's own roll along the bottom edge — only frames Snap took.
//

import SwiftUI
import UIKit

struct FilmStrip: View {

    @ObservedObject var store: ShotStore

    var selection: Shot?
    var onSelect: (Shot) -> Void
    var onToggleFavorite: (Shot) -> Void
    var onUseLook: (Shot) -> Void
    var onShare: ([URL]) -> Void
    var onDelete: (Shot) -> Void
    /// True in the develop panel, where a shot with no negative has nothing to
    /// re-develop and is shown as unavailable.
    var requiresNegative: Bool

    /// Thumbnails are decoded and held in memory, so the strip only reaches
    /// for a page at a time.
    private static let pageSize = 20
    private static let thumbnailEdge: CGFloat = 62

    @State private var visibleCount = FilmStrip.pageSize

    private var thumbnailEdge: CGFloat { FilmStrip.thumbnailEdge }

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of CameraView.
    init(store: ShotStore,
         selection: Shot?,
         onSelect: @escaping (Shot) -> Void,
         onToggleFavorite: @escaping (Shot) -> Void,
         onUseLook: @escaping (Shot) -> Void,
         onShare: @escaping ([URL]) -> Void,
         onDelete: @escaping (Shot) -> Void,
         requiresNegative: Bool) {
        self.store = store
        self.selection = selection
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onUseLook = onUseLook
        self.onShare = onShare
        self.onDelete = onDelete
        self.requiresNegative = requiresNegative
    }

    private var visible: [Shot] {
        Array(store.shots.prefix(visibleCount))
    }

    var body: some View {
        ScrollViewReader { proxy in
            strip
                // The panel's strip is a second window onto the same roll, and
                // it opens with a frame already chosen. Scrolling to it is what
                // makes the outline mean anything.
                .onAppear { reveal(selection, using: proxy) }
                // And every time the chosen frame moves after that: a swipe
                // across the frame above, one opened out of the favourites or
                // the grid, a negative stepped under the sliders. The strip is
                // where you are in the roll, so it keeps up rather than being
                // left several frames behind whatever is on screen.
                .onChange(of: selection?.id) { _, _ in
                    reveal(selection, using: proxy, animated: true)
                }
        }
        .frame(height: thumbnailEdge)
        // A shot deleted off the end shouldn't leave the window past the end
        // of the list.
        .onChange(of: store.shots.count) { _, count in
            visibleCount = max(FilmStrip.pageSize, min(visibleCount, max(count, FilmStrip.pageSize)))
        }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(visible) { shot in
                    let isUsable = !requiresNegative || store.rawURL(for: shot) != nil

                    ShotThumbnail(store: store,
                                  shot: shot,
                                  edge: thumbnailEdge,
                                  isSelected: shot.id == selection?.id)
                        .opacity(isUsable ? 1 : 0.3)
                        // Keeping a frame says nothing about whether it can be
                        // re-developed, so the double tap works on a dimmed
                        // thumbnail as the menu does. Declared first, which is
                        // what lets a single tap wait to see whether a second
                        // one is coming.
                        .onTapGesture(count: 2) { onToggleFavorite(shot) }
                        // The menu still applies — a preview frame can still be
                        // shared, deleted, or have its settings borrowed.
                        .onTapGesture { if isUsable { onSelect(shot) } }
                        .contextMenu {
                            Button {
                                onToggleFavorite(shot)
                            } label: {
                                Label(shot.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                      systemImage: shot.isFavorite ? "heart.slash" : "heart")
                            }

                            Button {
                                onUseLook(shot)
                            } label: {
                                Label("Use Develop Settings", systemImage: "camera.filters")
                            }

                            Button {
                                onShare([store.imageURL(for: shot)])
                            } label: {
                                Label("Share JPEG", systemImage: "square.and.arrow.up")
                            }

                            // Only offered when the capture was RAW and the
                            // negative is still on disk. The sidecar goes with
                            // it — apart they mean nothing.
                            if !store.negativeURLs(for: shot).isEmpty {
                                Button {
                                    onShare(store.negativeURLs(for: shot))
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

                if store.shots.count > visibleCount {
                    Button {
                        visibleCount += FilmStrip.pageSize
                    } label: {
                        Text("Load\nMore")
                            .font(.system(size: 11, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: thumbnailEdge, height: thumbnailEdge)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
    }

    /// Brings the chosen frame into view, widening the window first if it sits
    /// past the end of it.
    ///
    /// The panel's strip carries its own page count, so a frame picked from the
    /// camera screen's strip — where more may already have been loaded — can be
    /// off the end of this one. Asking to scroll to a row that isn't there
    /// does nothing, so the pages are added first and the scroll waits a turn
    /// for them to be laid out.
    ///
    /// A strip that is already up moves rather than jumps — the frame it is
    /// centring on is the one that just arrived above it, and seeing it travel
    /// there is what says which way along the roll you went.
    private func reveal(_ shot: Shot?, using proxy: ScrollViewProxy, animated: Bool = false) {
        guard let shot,
              let index = store.shots.firstIndex(where: { $0.id == shot.id }) else { return }

        if index >= visibleCount {
            visibleCount = (index / FilmStrip.pageSize + 1) * FilmStrip.pageSize
        }

        DispatchQueue.main.async {
            guard animated else {
                proxy.scrollTo(shot.id, anchor: .center)
                return
            }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(shot.id, anchor: .center)
            }
        }
    }
}
