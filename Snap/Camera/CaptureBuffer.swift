//
//  CaptureBuffer.swift
//  Snap
//
//  The frames the shutter has taken and nobody has developed yet.
//
//  A RAW frame is off the sensor in a fraction of a second, and then takes
//  several more to become a photograph: demosaiced, graded and encoded at full
//  resolution, its negative squared and written, the lot stored and handed to
//  the camera roll. The shutter used to wait for all of it. Now it waits only
//  for the sensor: the negative is written here as it arrives, the shutter is
//  free again, and the frames are developed one at a time, oldest first, behind
//  whatever is still being shot.
//
//  On disk rather than in memory. A negative is tens of megabytes, and a phone
//  goes into a pocket with frames still waiting — that is how a burst ends,
//  not an accident. Ten negatives held in memory by an app in the background
//  is what iOS ends apps for; ten files are not. Whatever is in the folder at
//  launch was left by a run that was ended, and is developed once the camera
//  is up.
//
//  Developing reaches for the GPU, which an app in the background may not do.
//  So the buffer stops when the camera stops and starts again when the camera
//  is back, and a frame caught halfway is developed again from the beginning
//  rather than trusted: a render cut off by the app leaving may come back
//  black, and a black frame would be filed as if it were the photograph.
//

import Foundation
import ImageIO

/// What the buffer needs from whoever owns the look, the store and the camera
/// roll — which is `CameraModel`, the same code the shutter used to run while
/// you waited.
protocol BufferDeveloper: AnyObject {
    /// Develops, crops, grades and encodes the frame. This is the part that
    /// reaches for the GPU, so it is only ever asked for in the foreground.
    func develop(_ negative: CaptureBuffer.Negative) throws -> Data
    /// Squares the negative and files the frame in the roll and the camera
    /// roll. Files only.
    func finish(_ negative: CaptureBuffer.Negative, jpeg: Data) throws
    /// A frame that could not be developed and has been given up on.
    func report(_ error: Error)
}

final class CaptureBuffer: ObservableObject {

    /// How many frames can wait at once before the shutter waits too.
    static let capacity = 10

    /// A frame as the roll shows it while it waits: where it goes in the roll,
    /// and how far along it is.
    struct Frame: Identifiable, Equatable {
        let id: UUID
        let takenAt: Date
        /// When its development started. Nil while it waits its turn.
        var startedAt: Date?
        /// How long that development is expected to take, which is what the
        /// last few took.
        var expected: TimeInterval
    }

    /// A frame as the darkroom needs it.
    struct Negative {
        let id: UUID
        let takenAt: Date
        let data: Data
        let isRAW: Bool
        /// The capture's own metadata, with the coordinate added as it came
        /// off the sensor.
        let metadata: [String: Any]
        let profile: PositiveFilmProfile
    }

    /// Newest first, the way the roll runs. Main thread only.
    @Published private(set) var frames: [Frame] = []

    /// Set once, before anything is admitted.
    weak var developer: BufferDeveloper?

    private let directory: URL
    private let queue = DispatchQueue(label: "com.snap.buffer", qos: .userInitiated)

    /// Guards the three below, which are written from the main thread and read
    /// from the buffer's queue.
    private let lock = NSLock()
    /// Stopped until the camera is first up, so a frame left over from an
    /// ended run doesn't take the GPU away from the camera starting.
    private var isSuspended = true
    /// Moves on every stop, so a development can tell it was overtaken by one.
    private var generation = 0
    /// What a development has been taking, kept across launches so the first
    /// ring after one is about right.
    private var expectedDuration: TimeInterval

    /// The frames whose turn hasn't come, oldest first. Buffer queue only.
    private var waiting: [UUID] = []

    private static let expectedDurationKey = "CaptureBuffer.expectedDuration"
    private static let defaultDuration: TimeInterval = 3

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stored = UserDefaults.standard.double(forKey: Self.expectedDurationKey)
        expectedDuration = stored > 0 ? stored : Self.defaultDuration

        let left = leftBehind()
        waiting = left.map { $0.id }
        frames = left.reversed().map {
            Frame(id: $0.id, takenAt: $0.takenAt, startedAt: nil, expected: expectedDuration)
        }
    }

    // MARK: - Taking frames in

    /// Puts a frame off the sensor in the queue.
    ///
    /// Called on the photo output's own queue, and written before it returns:
    /// once this is back the frame is on disk, nothing has to hold its tens of
    /// megabytes in memory, and the shutter can be let go.
    func admit(data: Data,
               isRAW: Bool,
               metadata: [String: Any],
               profile: PositiveFilmProfile,
               takenAt: Date) throws {
        let id = UUID()
        try data.write(to: dataURL(id, isRAW: isRAW))
        do {
            try writeRecord(id: id, takenAt: takenAt, isRAW: isRAW, profile: profile, metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: dataURL(id, isRAW: isRAW))
            throw error
        }

        let expected = locked { expectedDuration }
        DispatchQueue.main.async { [weak self] in
            self?.frames.insert(Frame(id: id, takenAt: takenAt, startedAt: nil, expected: expected), at: 0)
        }
        queue.async { [weak self] in
            self?.waiting.append(id)
            self?.drain()
        }
    }

    // MARK: - Stopping and starting

    /// The camera is stopping, which means the app is going to the background
    /// and the GPU is about to go with it.
    func suspend() {
        locked {
            isSuspended = true
            generation += 1
        }
    }

    /// The camera is up again.
    func resume() {
        locked { isSuspended = false }
        queue.async { [weak self] in self?.drain() }
    }

    // MARK: - Developing

    /// Works through the waiting frames, oldest first, until there are none or
    /// the buffer is stopped. Buffer queue only, which is what makes it one at
    /// a time: two developments at once would not finish sooner, and would
    /// hold two full-resolution frames in memory instead of one.
    private func drain() {
        while let id = waiting.first {
            guard let generation = locked({ () -> Int? in isSuspended ? nil : self.generation }) else {
                return
            }
            guard develop(id, generation: generation) else { return }
            waiting.removeFirst()
        }
    }

    /// One frame, start to finish. False when the buffer was stopped under it,
    /// which leaves it at the head of the queue for when it starts again.
    private func develop(_ id: UUID, generation: Int) -> Bool {
        guard let developer else { return false }

        guard let negative = negative(id) else {
            discard(id)
            developer.report(RAWDeveloper.DevelopError.undecodable)
            return true
        }

        let started = Date()
        let expected = locked { expectedDuration }
        onMain { buffer in
            buffer.update(id) { frame in
                frame.startedAt = started
                frame.expected = expected
            }
        }

        do {
            let jpeg = try developer.develop(negative)
            guard isCurrent(generation) else { return interrupted(id) }
            try developer.finish(negative, jpeg: jpeg)
        } catch {
            guard isCurrent(generation) else { return interrupted(id) }
            discard(id)
            developer.report(error)
            return true
        }

        learn(Date().timeIntervalSince(started))
        discard(id)
        return true
    }

    /// Back in line, with an empty ring, to be developed again from the start.
    private func interrupted(_ id: UUID) -> Bool {
        onMain { buffer in buffer.update(id) { frame in frame.startedAt = nil } }
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        locked { !isSuspended && self.generation == generation }
    }

    /// Done with: its files go, and so does its square in the roll.
    ///
    /// The square goes after the store has published the frame that replaces
    /// it — both hop to the main thread, in that order — so the roll is never
    /// left with a gap where the photograph is about to be.
    private func discard(_ id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: dataURL(id, isRAW: true))
        try? fileManager.removeItem(at: dataURL(id, isRAW: false))
        try? fileManager.removeItem(at: recordURL(id))
        onMain { buffer in buffer.frames.removeAll { $0.id == id } }
    }

    /// Weighted toward the latest, since what a development takes moves with
    /// the phone's temperature and with whatever else is running.
    private func learn(_ duration: TimeInterval) {
        let updated = locked { () -> TimeInterval in
            expectedDuration = expectedDuration * 0.5 + duration * 0.5
            return expectedDuration
        }
        UserDefaults.standard.set(updated, forKey: Self.expectedDurationKey)
    }

    // MARK: - On disk

    private func dataURL(_ id: UUID, isRAW: Bool) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(isRAW ? "dng" : "photo")")
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).plist")
    }

    /// Everything about a frame except its pixels, beside them as a property
    /// list. Written after the data, so a record on disk means a whole frame.
    private func writeRecord(id: UUID,
                             takenAt: Date,
                             isRAW: Bool,
                             profile: PositiveFilmProfile,
                             metadata: [String: Any]) throws {
        let profileData = try JSONEncoder().encode(profile)
        var record: [String: Any] = [
            "takenAt": takenAt,
            "isRAW": isRAW,
            "profile": profileData,
        ]

        var plist: Data
        do {
            record["metadata"] = metadata
            plist = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        } catch {
            // Something in the camera's metadata a property list can't hold.
            // The negative carries its own, which is what a version is made
            // from too; only the coordinate has to be kept by hand.
            record["metadata"] = nil
            record["gps"] = metadata[kCGImagePropertyGPSDictionary as String]
            plist = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        }
        try plist.write(to: recordURL(id), options: .atomic)
    }

    private struct Record {
        var takenAt: Date
        var isRAW: Bool
        var profile: PositiveFilmProfile
        var metadata: [String: Any]?
        var gps: [String: Any]?
    }

    private func record(_ id: UUID) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(id)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let takenAt = plist["takenAt"] as? Date,
              let isRAW = plist["isRAW"] as? Bool,
              let profileData = plist["profile"] as? Data,
              let profile = try? JSONDecoder().decode(PositiveFilmProfile.self, from: profileData) else {
            return nil
        }
        return Record(takenAt: takenAt,
                      isRAW: isRAW,
                      profile: profile,
                      metadata: plist["metadata"] as? [String: Any],
                      gps: plist["gps"] as? [String: Any])
    }

    private func negative(_ id: UUID) -> Negative? {
        guard let record = record(id),
              let data = try? Data(contentsOf: dataURL(id, isRAW: record.isRAW)) else {
            return nil
        }

        var metadata = record.metadata ?? RAWDeveloper.properties(of: data)
        if record.metadata == nil, let gps = record.gps {
            metadata[kCGImagePropertyGPSDictionary as String] = gps
        }

        return Negative(id: id,
                        takenAt: record.takenAt,
                        data: data,
                        isRAW: record.isRAW,
                        metadata: metadata,
                        profile: record.profile)
    }

    /// What a run that was ended left in the folder, oldest first. A record
    /// without its data, or data without its record, is half a write and is
    /// cleared away.
    private func leftBehind() -> [(id: UUID, takenAt: Date)] {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

        var found: [(id: UUID, takenAt: Date)] = []
        for url in urls where url.pathExtension == "plist" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let record = record(id),
                  fileManager.fileExists(atPath: dataURL(id, isRAW: record.isRAW).path) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            found.append((id: id, takenAt: record.takenAt))
        }

        let known = Set(found.map { $0.id })
        for url in urls where url.pathExtension != "plist" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
               known.contains(id) {
                continue
            }
            try? fileManager.removeItem(at: url)
        }

        return found.sorted { $0.takenAt < $1.takenAt }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func onMain(_ change: @escaping (CaptureBuffer) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            change(self)
        }
    }

    /// Main thread only.
    private func update(_ id: UUID, _ change: (inout Frame) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        change(&frames[index])
    }
}
