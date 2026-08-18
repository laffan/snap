//
//  LookModel.swift
//  Snap
//
//  Holds the live profile and keeps a baked filter in step with it.
//
//  This is deliberately separate from CameraModel. The filter panel mutates
//  the profile on every frame of a drag; if that lived on CameraModel, every
//  slider tick would invalidate the whole camera screen. Here only the panel
//  observes it.
//

import Combine
import Foundation

final class LookModel: ObservableObject {

    /// The live profile. Mutating it schedules a re-bake.
    @Published var profile: PositiveFilmProfile {
        didSet {
            guard profile != oldValue else { return }
            requestBake()
        }
    }

    /// True while a slider is being dragged. Drags bake at draft resolution so
    /// the preview keeps up; letting go commits a full-resolution bake.
    private var isInteracting = false

    private let lock = NSLock()
    private var bakedFilter: PositiveFilmFilter?
    private var requested: BakeRequest

    private let bakeQueue = DispatchQueue(label: "com.snap.bake", qos: .userInitiated)

    private struct BakeRequest: Equatable {
        var profile: PositiveFilmProfile
        var resolution: PositiveFilmFilter.Resolution
    }

    init(profile: PositiveFilmProfile = PositiveFilmProfile()) {
        self.profile = profile
        self.requested = BakeRequest(profile: profile, resolution: .final)
    }

    /// The filter to render with. Read from the capture queue on every frame.
    ///
    /// Before the first edit this falls through to the shared default, which
    /// bakes itself lazily on whichever thread asks first — keeping the cost
    /// off the main thread at launch.
    var filter: PositiveFilmFilter {
        lock.lock()
        defer { lock.unlock() }
        return bakedFilter ?? .standard
    }

    /// A guaranteed full-resolution filter for `profile`, reusing the baked
    /// one when it already matches. Captures go through this so a still is
    /// never graded by the draft LUT that a drag left behind.
    func finalFilter(for profile: PositiveFilmProfile) -> PositiveFilmFilter {
        lock.lock()
        let cached = bakedFilter
        lock.unlock()

        if let cached, cached.resolution == .final, cached.profile == profile {
            return cached
        }
        return PositiveFilmFilter(profile: profile, resolution: .final)
    }

    /// Hook for `Slider(onEditingChanged:)`.
    func setInteracting(_ interacting: Bool) {
        guard interacting != isInteracting else { return }
        isInteracting = interacting
        // Letting go of a slider upgrades the draft bake to a final one.
        if !interacting { requestBake() }
    }

    func reset() {
        profile = PositiveFilmProfile()
    }

    func apply(_ preset: Preset) {
        profile = preset.profile
    }

    // MARK: - Baking

    private func requestBake() {
        let request = BakeRequest(profile: profile,
                                  resolution: isInteracting ? .draft : .final)
        lock.lock()
        requested = request
        lock.unlock()

        bakeQueue.async { [weak self] in
            guard let self else { return }

            // Coalesce: during a drag many requests pile up behind one bake.
            // Only the newest is worth the work — the rest fall out here.
            self.lock.lock()
            let isCurrent = self.requested == request
            self.lock.unlock()
            guard isCurrent else { return }

            let filter = PositiveFilmFilter(profile: request.profile,
                                            resolution: request.resolution)

            self.lock.lock()
            // A newer request may have landed while this was baking; don't let
            // a stale result overwrite it.
            if self.requested == request {
                self.bakedFilter = filter
            }
            self.lock.unlock()
        }
    }
}
