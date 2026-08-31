//
//  LookModel.swift
//  Snap
//
//  Holds the live profile and keeps a baked filter in step with it.
//
//  This is deliberately separate from CameraModel. The develop panel mutates
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

    /// Bumped whenever a freshly baked filter lands. The live camera preview
    /// picks up new looks on its next frame, but a still being re-filtered has
    /// no next frame — it redraws off this.
    @Published private(set) var revision = 0

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
        self.requested = BakeRequest(profile: profile.resolved, resolution: .final)
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
    ///
    /// Resolved on the way in, like every other bake: what is stored keeps the
    /// base profile and its sub-profiles apart, and what is *rendered* is the
    /// one with the other laid over it.
    func finalFilter(for profile: PositiveFilmProfile) -> PositiveFilmFilter {
        let resolved = profile.resolved

        lock.lock()
        let cached = bakedFilter
        lock.unlock()

        if let cached, cached.resolution == .final, cached.profile == resolved {
            return cached
        }
        return PositiveFilmFilter(profile: resolved, resolution: .final)
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

    func apply(_ profile: PositiveFilmProfile) {
        self.profile = profile
    }

    /// Moves one of the settings a sub-profile is allowed to hold, and takes it
    /// back off whichever one is holding it.
    ///
    /// The develop panel's Temperature, Exposure and Shadows sliders write
    /// through here, and so do the exposure stepper and the meter readout on
    /// the camera screen — the two other ways Exposure is reached. One mutation
    /// rather than two, so a drag costs one bake per tick rather than two.
    ///
    /// The claim is recorded even when the number lands where it already was:
    /// double-tapping Exposure back to zero under a lit Night is a hand on the
    /// slider saying zero, and it has to mean zero.
    func setByHand(_ setting: SubProfile.Setting, to value: Float) {
        var updated = profile
        updated.setByHand(setting, to: value)
        profile = updated
    }

    // MARK: - Baking

    private func requestBake() {
        let request = BakeRequest(profile: profile.resolved,
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
            let isNewest = self.requested == request
            if isNewest {
                self.bakedFilter = filter
            }
            self.lock.unlock()

            if isNewest {
                DispatchQueue.main.async { self.revision &+= 1 }
            }
        }
    }
}
