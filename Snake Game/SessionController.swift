//
//  SessionController.swift
//  Snake Game
//
//  Runs one session: instructions → 1-minute baseline rest → countdown → the timed
//  following task → 1-minute recovery rest, then saves the log automatically.
//  Every boundary is stamped by the app.
//

import Foundation
import Observation

enum SessionPhase: String {
    /// `ready`: instructions are showing and the session waits for the participant to start the baseline.
    case idle, ready, baseline, countdown, task, recovery, complete

    var isActive: Bool { self != .idle && self != .complete }
    var isRest: Bool { self == .baseline || self == .recovery }
}

@MainActor
@Observable
final class SessionController {
    /// Lengths the participant can pick on the start screen.
    static let durationOptions = [60, 180, 300]
    static let countdownSeconds = 3
    /// Normal resting breathing (12 per minute) for the paced rest scene. Not slow paced breathing,
    /// which would raise HRV and stop being a resting baseline.
    static let inhaleSeconds: TimeInterval = 2
    static let exhaleSeconds: TimeInterval = 3
    static var breathCycle: TimeInterval { inhaleSeconds + exhaleSeconds }
    /// Speed (box units per second) at the start and in the final 10 seconds, whatever the length.
    /// The 10-unit box is crossed in 5 s at the start and in about 1.2 s at the peak.
    static let startSpeed: Float = 2
    static let peakSpeed: Float = 8
    static let speedIncreaseInterval: TimeInterval = 10
    /// A gap between clock ticks longer than this during the task is logged as a stall.
    static let stallThreshold: TimeInterval = 0.25

    /// False when the immersive space could not open and the game runs in the window.
    var runsImmersive = true
    /// Chosen on the start screen.
    var taskSeconds = 60
    /// Baseline and recovery rest length.
    var restSeconds = 60

    /// Equal speed steps every 10 s so the last 10-second block runs at `peakSpeed`.
    var speedStep: Float {
        let increases = max(1, taskSeconds / Int(Self.speedIncreaseInterval) - 1)
        return (Self.peakSpeed - Self.startSpeed) / Float(increases)
    }

    private(set) var game = FollowGame()
    private(set) var phase: SessionPhase = .idle
    private(set) var phaseStartedAt: Date?
    private(set) var phaseEndsAt: Date?
    private(set) var savedFiles: [URL] = []
    private(set) var saveError: String?
    private(set) var wasAborted = false

    private(set) var headSamples: [HeadSample] = []
    private var sessionStart: Date?
    private var boundaries: [String: Date] = [:]
    private var stallCount = 0
    private var lastTick: Date?
    private var loop: Task<Void, Never>?

    var isActive: Bool { phase.isActive }

    func remaining(at now: Date = .now) -> TimeInterval {
        guard let phaseEndsAt else { return 0 }
        return max(0, phaseEndsAt.timeIntervalSince(now))
    }

    func progress(at now: Date = .now) -> Double {
        guard let start = phaseStartedAt, let end = phaseEndsAt, end > start else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }

    /// Seconds into the current phase.
    func elapsed(at now: Date = .now) -> TimeInterval {
        guard let start = phaseStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// Breathing guide: 0 = fully out, 1 = fully in. Eased so the motion has no sudden changes.
    func breath(at now: Date = .now) -> Float {
        let t = elapsed(at: now).truncatingRemainder(dividingBy: Self.breathCycle)
        let x: Double = t < Self.inhaleSeconds
            ? t / Self.inhaleSeconds
            : 1 - (t - Self.inhaleSeconds) / Self.exhaleSeconds
        return Float(x * x * (3 - 2 * x))
    }

    /// True while the guide is in the breathing-in part of the cycle.
    func isInhaling(at now: Date = .now) -> Bool {
        elapsed(at: now).truncatingRemainder(dividingBy: Self.breathCycle) < Self.inhaleSeconds
    }

    // MARK: - Lifecycle

    func begin(at now: Date = .now) {
        loop?.cancel()
        game = FollowGame(
            speed: Self.startSpeed,
            speedStep: speedStep,
            speedIncreaseInterval: Self.speedIncreaseInterval,
            maxSpeed: Self.peakSpeed
        )
        headSamples = []
        savedFiles = []
        saveError = nil
        wasAborted = false
        boundaries = [:]
        stallCount = 0
        sessionStart = now
        lastTick = now

        game.mark(
            "session_begin baseline_s=\(restSeconds) task_s=\(taskSeconds) recovery_s=\(restSeconds) start_speed=\(Self.startSpeed) peak_speed=\(Self.peakSpeed) step=\(String(format: "%.3f", speedStep)) every_s=\(Int(Self.speedIncreaseInterval)) immersive=\(runsImmersive) utc_offset=\(LogClock.utcOffset)",
            at: now
        )
        boundaries["session_start"] = now
        enter(.ready, at: now)

        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(now: .now)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// The participant read the instructions and pressed Start baseline.
    func startBaseline(at now: Date = .now) {
        guard phase == .ready else { return }
        game.mark("participant_pressed_start", at: now)
        boundaries["instructions_end"] = now
        enter(.baseline, at: now)
    }

    /// Ends the session early. Whatever was recorded is still saved.
    func abort(reason: String, at now: Date = .now) {
        guard phase.isActive else { return }
        if phase == .ready {
            // Nothing was recorded yet; just go back to the start screen.
            reset()
            return
        }
        if game.isRunning { game.stop(at: now) }
        game.mark("session_aborted reason=\(reason) during=\(phase.rawValue)", at: now)
        boundaries["\(phase.rawValue)_end"] = now
        wasAborted = true
        finish(at: now)
    }

    func reset() {
        loop?.cancel()
        loop = nil
        phase = .idle
        phaseStartedAt = nil
        phaseEndsAt = nil
        game = FollowGame()
    }

    /// Head pose from the headset during the rests and the task (about 20 per second when available).
    func recordHead(_ sample: HeadSample) {
        guard phase.isRest || phase == .task else { return }
        headSamples.append(sample)
    }

    // MARK: - Clock

    private func tick(now: Date) {
        guard phase.isActive, phase != .ready, let last = lastTick else { return }
        // Never run the game past the scheduled phase end, so boundaries land exactly on time.
        let target = min(now, phaseEndsAt ?? now)
        let gap = target.timeIntervalSince(last)
        if phase == .task, gap > Self.stallThreshold {
            // The app was blocked and the snake froze for this long. Flag it so the window can be excluded.
            stallCount += 1
            game.mark("frame_stall gap_ms=\(Int((gap * 1000).rounded())) from_unix_ms=\(LogClock.unixMillis(last))", at: target)
        }
        lastTick = target
        if phase == .task, gap > 0 {
            game.tick(deltaTime: min(gap, 0.05), now: target)
        }
        if let end = phaseEndsAt, target >= end {
            advance(at: end)
        }
    }

    private func advance(at time: Date) {
        switch phase {
        case .baseline:
            game.mark("baseline_end", at: time)
            boundaries["baseline_end"] = time
            enter(.countdown, at: time)
        case .countdown:
            game.mark("countdown_end", at: time)
            enter(.task, at: time)
        case .task:
            game.stop(at: time)
            game.mark("task_end", at: time)
            boundaries["task_end"] = time
            enter(.recovery, at: time)
        case .recovery:
            game.mark("recovery_end", at: time)
            boundaries["recovery_end"] = time
            finish(at: time)
        default:
            break
        }
    }

    private func enter(_ next: SessionPhase, at time: Date) {
        phase = next
        phaseStartedAt = time
        lastTick = time
        let breathing = "breathing_per_min=\(Int(60 / Self.breathCycle)) inhale_s=\(Int(Self.inhaleSeconds)) exhale_s=\(Int(Self.exhaleSeconds)) scene=moonlit_lake"
        switch next {
        case .ready:
            phaseEndsAt = nil
            game.mark("instructions_shown", at: time)
        case .baseline:
            phaseEndsAt = time.addingTimeInterval(TimeInterval(restSeconds))
            boundaries["baseline_start"] = time
            game.mark("baseline_start rest_s=\(restSeconds) \(breathing)", at: time)
        case .recovery:
            phaseEndsAt = time.addingTimeInterval(TimeInterval(restSeconds))
            boundaries["recovery_start"] = time
            game.mark("recovery_start rest_s=\(restSeconds) \(breathing)", at: time)
        case .countdown:
            phaseEndsAt = time.addingTimeInterval(TimeInterval(Self.countdownSeconds))
            game.mark("countdown_start", at: time)
        case .task:
            phaseEndsAt = time.addingTimeInterval(TimeInterval(taskSeconds))
            boundaries["task_start"] = time
            game.mark("task_start", at: time)
            game.start(at: time)
        default:
            phaseEndsAt = nil
        }
    }

    private func finish(at time: Date) {
        loop?.cancel()
        loop = nil
        game.mark("session_end", at: time)
        boundaries["session_end"] = time
        autosave()
        phase = .complete
        phaseEndsAt = nil
    }

    // MARK: - Saving

    /// Shown in Files as On My Apple Vision Pro › Snake Game.
    static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Spreadsheet copies for analysis live one level down so the main folder stays tidy.
    static var sessionsDirectory: URL? {
        documentsDirectory?.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// The readable log, e.g. snake-test-log_2026-11-08_20-13-16.txt, saved straight into the app's folder.
    var logFile: URL? { savedFiles.first }

    /// Turns the snake made during the task.
    var turnCount: Int { game.log.filter { $0.kind == .changedDirection }.count }

    /// Fastest speed reached, in box units per second.
    var topSpeed: Float { game.log.map(\.speed).max() ?? Self.startSpeed }

    /// How long the snake actually ran (shorter than chosen if stopped early).
    var taskDuration: TimeInterval {
        guard let start = boundaries["task_start"] else { return 0 }
        let end = boundaries["task_end"] ?? boundaries["session_end"] ?? start
        return max(0, end.timeIntervalSince(start))
    }

    private func autosave() {
        guard let root = Self.documentsDirectory, let dir = Self.sessionsDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = "snake-test-log_" + LogClock.fileStamp.string(from: sessionStart ?? .now)
            let txt = root.appendingPathComponent(base + ".txt")
            let csv = dir.appendingPathComponent(base + ".csv")
            try Data(game.logText.utf8).write(to: txt, options: .atomic)
            try Data(game.csvText.utf8).write(to: csv, options: .atomic)
            var files = [txt, csv]
            if !headSamples.isEmpty {
                let head = dir.appendingPathComponent(base + "_head.csv")
                try Data(HeadSample.csv(headSamples).utf8).write(to: head, options: .atomic)
                files.append(head)
            }
            files.append(try appendSummary(file: base, in: dir))
            savedFiles = files
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// One row per session with the task window in unix ms, ready to join with sensor data.
    private func appendSummary(file: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("sessions_summary.csv")
        let keys = ["session_start", "instructions_end", "baseline_start", "baseline_end", "task_start", "task_end",
                    "recovery_start", "recovery_end", "session_end"]
        let offTarget = headSamples.filter { $0.phase == .task }.map(\.offTargetDegrees)
        let meanOffTarget = offTarget.isEmpty ? "" : String(format: "%.2f", offTarget.reduce(0, +) / Float(offTarget.count))
        let header = (["file", "rest_s", "task_s", "completed", "immersive", "frame_stalls", "head_samples",
                       "mean_head_off_target_deg", "utc_offset"]
            + keys.map { $0 + "_unix_ms" }).joined(separator: ",")
        let row = ([file, String(restSeconds), String(taskSeconds), String(!wasAborted), String(runsImmersive), String(stallCount),
                    String(headSamples.count), meanOffTarget, LogClock.utcOffset]
            + keys.map { boundaries[$0].map { String(LogClock.unixMillis($0)) } ?? "" }).joined(separator: ",")

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((row + "\n").utf8))
        } else {
            try Data((header + "\n" + row + "\n").utf8).write(to: url, options: .atomic)
        }
        return url
    }
}

/// Where the participant's head pointed relative to the snake. visionOS does not give apps eye
/// tracking, so head direction is the closest available proxy for following.
struct HeadSample {
    let time: Date
    let phase: SessionPhase
    let position: SIMD3<Float>
    let yawDegrees: Float
    let pitchDegrees: Float
    /// Angle between where the head points and the snake's head (during the task)
    /// or the moon's reflection on the lake (during the rests).
    let offTargetDegrees: Float

    static func csv(_ samples: [HeadSample]) -> String {
        var rows = ["unix_ms,timestamp,phase,head_x,head_y,head_z,yaw_deg,pitch_deg,off_target_deg"]
        rows.reserveCapacity(samples.count + 1)
        for s in samples {
            rows.append([
                String(LogClock.unixMillis(s.time)),
                LogClock.string(from: s.time),
                s.phase.rawValue,
                String(format: "%.3f", s.position.x),
                String(format: "%.3f", s.position.y),
                String(format: "%.3f", s.position.z),
                String(format: "%.1f", s.yawDegrees),
                String(format: "%.1f", s.pitchDegrees),
                String(format: "%.1f", s.offTargetDegrees),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
