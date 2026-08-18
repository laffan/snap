//
//  LoadPresetSheet.swift
//  Snap
//
//  Every saved moment, newest first. Tap one to put its settings back on the
//  sliders.
//

import SwiftUI
import UIKit

struct LoadPresetSheet: View {

    @ObservedObject var store: PresetStore
    var onSelect: (Preset) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.presets.isEmpty {
                    ContentUnavailableView("No Saved Looks",
                                           systemImage: "camera.filters",
                                           description: Text("Use Save in the filter panel to keep a look and the frame it made."))
                } else {
                    List {
                        ForEach(store.presets) { preset in
                            Button { onSelect(preset) } label: {
                                PresetCard(store: store, preset: preset)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { store.presets[$0] }.forEach(store.delete)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Load Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onCancel)
                }
            }
        }
    }
}

private struct PresetCard: View {

    @ObservedObject var store: PresetStore
    let preset: Preset

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
                Text(preset.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                Text(Self.dateFormatter.string(from: preset.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !preset.notes.isEmpty {
                    Text(preset.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task(id: preset.id) {
            guard thumbnail == nil else { return }
            let url = store.imageURL(for: preset)
            thumbnail = await Task.detached(priority: .userInitiated) {
                PresetStore.thumbnail(at: url, maxPixelSize: 180)
            }.value
        }
    }
}
