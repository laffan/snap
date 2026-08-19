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
    var onUseLook: (Shot) -> Void
    var onShare: ([URL]) -> Void
    var onDelete: (Shot) -> Void
    /// True in the filter panel, where a shot with no negative has nothing to
    /// re-filter and is shown as unavailable.
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
         onUseLook: @escaping (Shot) -> Void,
         onShare: @escaping ([URL]) -> Void,
         onDelete: @escaping (Shot) -> Void,
         requiresNegative: Bool) {
        self.store = store
        self.selection = selection
        self.onSelect = onSelect
        self.onUseLook = onUseLook
        self.onShare = onShare
        self.onDelete = onDelete
        self.requiresNegative = requiresNegative
    }

    private var visible: [Shot] {
        Array(store.shots.prefix(visibleCount))
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(visible) { shot in
                    let isUsable = !requiresNegative || store.rawURL(for: shot) != nil

                    Thumbnail(store: store,
                              shot: shot,
                              edge: thumbnailEdge,
                              isSelected: shot.id == selection?.id)
                        .opacity(isUsable ? 1 : 0.3)
                        // The menu still applies — a preview frame can still be
                        // shared, deleted, or have its settings borrowed.
                        .onTapGesture { if isUsable { onSelect(shot) } }
                        .contextMenu {
                            Button {
                                onUseLook(shot)
                            } label: {
                                Label("Use Filter Settings", systemImage: "camera.filters")
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
        .frame(height: thumbnailEdge)
        // A shot deleted off the end shouldn't leave the window past the end
        // of the list.
        .onChange(of: store.shots.count) { _, count in
            visibleCount = max(FilmStrip.pageSize, min(visibleCount, max(count, FilmStrip.pageSize)))
        }
    }
}

private struct Thumbnail: View {

    @ObservedObject var store: ShotStore
    let shot: Shot
    let edge: CGFloat
    let isSelected: Bool

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
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .task(id: shot.id) {
            guard image == nil else { return }
            let url = store.imageURL(for: shot)
            // 3x covers the densest iPhone screen; at this size the decoded
            // thumbnail is still tiny.
            let pixels = edge * 3
            image = await Task.detached(priority: .userInitiated) {
                ShotStore.image(at: url, maxPixelSize: pixels)
            }.value
        }
    }
}
