//
//  FilmStrip.swift
//  Snap
//
//  The app's own roll along the bottom edge — only frames Snap took, and the
//  ones it has taken and is still developing.
//

import SwiftUI
import UIKit

struct FilmStrip: View {

    @ObservedObject var store: ShotStore
    /// The shutter's frames that haven't landed yet, each shown as a square
    /// with a ring where its thumbnail is going to be.
    @ObservedObject var buffer: CaptureBuffer

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
         buffer: CaptureBuffer,
         selection: Shot?,
         onSelect: @escaping (Shot) -> Void,
         onToggleFavorite: @escaping (Shot) -> Void,
         onUseLook: @escaping (Shot) -> Void,
         onShare: @escaping ([URL]) -> Void,
         onDelete: @escaping (Shot) -> Void,
         requiresNegative: Bool) {
        self.store = store
        self.buffer = buffer
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

    /// One place in the strip: a frame in the store, or one still developing.
    private enum Item: Identifiable {
        case shot(Shot)
        case developing(CaptureBuffer.Frame)

        var id: UUID {
            switch self {
            case .shot(let shot): return shot.id
            case .developing(let frame): return frame.id
            }
        }

        var date: Date {
            switch self {
            case .shot(let shot): return shot.createdAt
            case .developing(let frame): return frame.takenAt
            }
        }
    }

    /// The visible page with the developing frames laid in by when they were
    /// taken, which is where each one's thumbnail lands — a PS taken while the
    /// buffer is still working sits after the frames shot before it, not ahead
    /// of them.
    ///
    /// A frame the store has already published is left out of the buffer's
    /// list even if its square hasn't been taken away yet: the two share an
    /// id, and for that moment the thumbnail is the one to show.
    private var items: [Item] {
        let shots = visible
        let landed = Set(shots.map { $0.id })
        let developing = buffer.frames.filter { !landed.contains($0.id) }
        guard !developing.isEmpty else { return shots.map { Item.shot($0) } }

        return (developing.map { Item.developing($0) } + shots.map { Item.shot($0) })
            .sorted { $0.date > $1.date }
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
                ForEach(items) { item in
                    switch item {
                    case .shot(let shot):
                        thumbnail(for: shot)
                    case .developing(let frame):
                        DevelopingThumbnail(frame: frame, edge: thumbnailEdge)
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

    /// A frame in the store: tap to open, double tap to keep, hold for the
    /// menu.
    @ViewBuilder
    private func thumbnail(for shot: Shot) -> some View {
        let isUsable = !requiresNegative || store.rawURL(for: shot) != nil

        ShotThumbnail(store: store,
                      shot: shot,
                      edge: thumbnailEdge,
                      isSelected: shot.id == selection?.id)
            .opacity(isUsable ? 1 : 0.3)
            // Keeping a frame says nothing about whether it can be re-developed,
            // so the double tap works on a dimmed thumbnail as the menu does.
            // Declared first, which is what lets a single tap wait to see
            // whether a second one is coming.
            .onTapGesture(count: 2) { onToggleFavorite(shot) }
            // The menu still applies — a preview frame can still be shared,
            // deleted, or have its settings borrowed.
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

                // Only offered when the capture was RAW and the negative is
                // still on disk. The sidecar goes with it — apart they mean
                // nothing.
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

/// A frame the shutter has taken and the buffer hasn't developed yet: a square
/// where its thumbnail will be, with a ring that fills while it develops.
///
/// Nothing to tap and nothing to hold. There is no photograph here yet — only
/// a negative on disk — so there is nothing to open, keep, share or delete.
///
/// The ring is an estimate rather than a report. A full-resolution development
/// says nothing about itself until it is finished, so the ring fills over
/// however long the last few took, stops just short of full, and waits there
/// for the photograph: a slow one reads as nearly done, never as done. A frame
/// still waiting its turn shows the ring empty.
private struct DevelopingThumbnail: View {

    let frame: CaptureBuffer.Frame
    let edge: CGFloat

    /// Where the ring stops until the frame lands.
    private static let ceiling = 0.95

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            // The same grey a thumbnail shows while it decodes, so the
            // photograph arriving is the only change.
            .fill(Color.white.opacity(0.07))
            .frame(width: edge, height: edge)
            .overlay {
                if let startedAt = frame.startedAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        ring(progress(at: context.date, since: startedAt))
                    }
                } else {
                    ring(0)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Developing")
    }

    private func ring(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: edge * 0.36, height: edge * 0.36)
    }

    private func progress(at date: Date, since start: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(start))
        let expected = max(frame.expected, 0.1)
        return min(Self.ceiling, Self.ceiling * elapsed / expected)
    }
}
