//
//  LoadLookSheet.swift
//  Snap
//
//  Every shot the app has taken, newest first. Tap one to put the settings it
//  was taken with back on the sliders.
//

import SwiftUI
import UIKit

struct LoadLookSheet: View {

    @ObservedObject var store: ShotStore
    var onSelect: (Shot) -> Void
    /// Swiping a row away deletes the photograph, camera roll and all, so it
    /// goes through the camera screen rather than straight to the store.
    var onDelete: (Shot) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.shots.isEmpty {
                    ContentUnavailableView("No Shots Yet",
                                           systemImage: "camera.filters",
                                           description: Text("Every photo you take keeps the settings that made it."))
                } else {
                    List {
                        ForEach(store.shots) { shot in
                            Button { onSelect(shot) } label: {
                                ShotRow(store: store, shot: shot)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { store.shots[$0] }.forEach(onDelete)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Load Develop Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onCancel)
                }
            }
        }
    }
}

private struct ShotRow: View {

    @ObservedObject var store: ShotStore
    let shot: Shot

    @State private var thumbnail: UIImage? = nil

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(shot.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                Text(Self.dateFormatter.string(from: shot.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !shot.notes.isEmpty {
                    Text(shot.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task(id: shot.id) {
            guard thumbnail == nil else { return }
            let url = store.imageURL(for: shot)
            thumbnail = await Task.detached(priority: .userInitiated) {
                ShotStore.image(at: url, maxPixelSize: 180)
            }.value
        }
    }
}
