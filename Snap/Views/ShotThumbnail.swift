//
//  ShotThumbnail.swift
//  Snap
//
//  One frame as a square, wherever frames are shown as squares: the roll along
//  the bottom edge, and the grid of favourites.
//
//  Two corners carry marks. Top right says where the frame came from — a dot
//  for a preview frame, a square for one made in the develop screen, nothing
//  for the shutter. Bottom left says it was kept.
//

import SwiftUI
import UIKit

struct ShotThumbnail: View {

    @ObservedObject var store: ShotStore
    let shot: Shot
    let edge: CGFloat
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 4

    @State private var image: UIImage? = nil

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of the roll.
    init(store: ShotStore,
         shot: Shot,
         edge: CGFloat,
         isSelected: Bool = false,
         cornerRadius: CGFloat = 4) {
        self.store = store
        self.shot = shot
        self.edge = edge
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
    }

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
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
        }
        .overlay(alignment: .topTrailing) { originMark }
        .overlay(alignment: .bottomLeading) { favoriteMark }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
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

    /// Marks the frames the shutter didn't take. The drop shadow is what keeps
    /// white legible against a blown-out corner.
    @ViewBuilder
    private var originMark: some View {
        switch shot.origin {
        case .camera:
            EmptyView()
        case .preview:
            mark(Circle())
        case .develop:
            mark(Rectangle())
        }
    }

    private func mark(_ shape: some Shape) -> some View {
        shape
            .fill(Color.white)
            .frame(width: 5, height: 5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .padding(5)
    }

    /// White rather than the accent, because this corner is one of a pair and
    /// the pair should read as one language.
    @ViewBuilder
    private var favoriteMark: some View {
        if shot.isFavorite {
            Image(systemName: "heart.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .padding(5)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
