//
//  SaveShotSheet.swift
//  Snap
//
//  Names a frame that has already been captured and stored.
//

import SwiftUI
import UIKit

struct SaveShotSheet: View {

    @ObservedObject var store: ShotStore
    let shot: Shot
    var onCancel: () -> Void
    var onSave: (_ title: String, _ caption: String) -> Void

    @State private var title: String
    @State private var caption: String
    @State private var image: UIImage? = nil
    @FocusState private var captionFocused: Bool

    // Explicit because the private state below would otherwise make the
    // memberwise initializer private.
    init(store: ShotStore,
         shot: Shot,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String, String) -> Void) {
        self.store = store
        self.shot = shot
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: shot.displayTitle)
        _caption = State(initialValue: shot.caption)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                    }
                }

                Section("Title") {
                    TextField("Title", text: $title)
                        .submitLabel(.next)
                        .onSubmit { captionFocused = true }
                }

                Section("Caption") {
                    TextField("What were you shooting?", text: $caption, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($captionFocused)
                }
            }
            .task {
                let url = store.imageURL(for: shot)
                image = await Task.detached(priority: .userInitiated) {
                    ShotStore.image(at: url, maxPixelSize: 900)
                }.value
            }
            .navigationTitle("Save Develop Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed, caption)
                    }
                }
            }
        }
    }
}
