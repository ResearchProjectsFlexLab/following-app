//
//  FollowGame.swift
//  Snake Game
//
//  Created by Prisha Marpu on 10/2/26.
//

import Foundation
import Observation
import os
import simd

enum MoveDirection: String, CaseIterable {
    case up, down, left, right

    var vector: SIMD2<Float> {
        switch self {
        case .up: SIMD2(0, 1)
        case .down: SIMD2(0, -1)
        case .left: SIMD2(-1, 0)
        case .right: SIMD2(1, 0)
        }
    }

    var clockwise: MoveDirection {
        switch self {
        case .up: .right
        case .right: .down
        case .down: .left
        case .left: .up
        }
    }

    var counterClockwise: MoveDirection { clockwise.opposite }

    var opposite: MoveDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

enum MovementEventKind: String {
    case session
    case started
    case moving
    case changedDirection
    case increasedSpeed
    case stopped
    /// A protocol marker (phase boundary, rating, sync point) written by `SessionController`.
    case marker
}

enum TurnReason: String {
    case edge = "reached the edge"
    case timer = "random turn"
}

struct MovementLogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: MovementEventKind
    let direction: MoveDirection
    let previousDirection: MoveDirection?
    let position: SIMD2<Float>
    let speed: Float
    /// Seconds since the first entry of this session (monotonic within a session).
    let elapsed: TimeInterval
    let note: String?
    let line: String

    /// Milliseconds since 1970-01-01 UTC, for aligning with ECG/EDA/PPG streams.
    var unixMillis: Int64 { LogClock.unixMillis(timestamp) }
}

enum LogClock {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func unixMillis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// UTC offset of the device clock, e.g. "-05:00".
    static var utcOffset: String {
        let seconds = TimeZone.current.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

enum MovementLogFile {
    static var fileURL: URL? {
        // Running crash-safe copy of every line; kept out of the main folder.
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sessions", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("movement-log.txt")
    }

    static func append(_ line: String) {
        guard let url = fileURL else { return }
        let payload = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

/// Moves an object inside a flat 10×10 box and records every direction with a timestamp.
@MainActor
@Observable
final class FollowGame {
    static let maxTrailCount = 16
    static let boxSize = SIMD2<Float>(10, 10)

    private(set) var speed: Float
    let speedStep: Float
    let speedIncreaseInterval: TimeInterval
    let heartbeatInterval: TimeInterval
    /// How far (in box units) the snake travels before a random turn. Drawn fresh after every turn.
    let turnDistance: ClosedRange<Float>
    /// Speed never goes above this, so a ramp can end at a known peak.
    let maxSpeed: Float
    let persistsLog: Bool
    private let initialSpeed: Float

    private(set) var isRunning = false
    private(set) var direction: MoveDirection = .right
    private(set) var position: SIMD2<Float> = SIMD2(2, 5)
    private(set) var trail: [SIMD2<Float>] = []
    private(set) var log: [MovementLogEntry] = []

    private let minimumRunway: Float = 0.2
    private var edgeMargin: Float = 0.45
    private let movementLogger = Logger(subsystem: "FlexLab.Snake-Game", category: "Movement")
    private var center = SIMD2<Float>(5, 5)
    private var halfExtents = SIMD2<Float>(5, 5)
    private var distanceToTurn: Float = .infinity
    private var nextSpeedIncrease: Date = .distantFuture
    private var lastHeartbeat: Date = .distantPast
    private var origin: Date?

    var boundsMin: SIMD2<Float> { center - halfExtents }
    var boundsMax: SIMD2<Float> { center + halfExtents }

    /// Plain-text export of every logged event, in the order it was written.
    var logText: String {
        var lines = [
            "Snake Game log",
            "Generated: \(LogClock.string(from: log.last?.timestamp ?? .now))",
            "Entries: \(log.count)",
            "Clock: device local time, UTC\(LogClock.utcOffset). The CSV export also has unix_ms for sensor alignment.",
            "A line is written when the speed changes.",
            "",
        ]
        lines.append(contentsOf: log.map(\.line))
        return lines.joined(separator: "\n")
    }

    /// Spreadsheet export of every logged event, including timestamps.
    var csvText: String {
        var rows = ["unix_ms,timestamp,elapsed_s,event,direction,previous_direction,x,y,speed,message"]
        rows.reserveCapacity(log.count + 1)
        for entry in log {
            let fields = [
                String(entry.unixMillis),
                LogClock.string(from: entry.timestamp),
                String(format: "%.3f", entry.elapsed),
                entry.kind.rawValue,
                entry.direction.rawValue,
                entry.previousDirection?.rawValue ?? "",
                String(format: "%.2f", entry.position.x),
                String(format: "%.2f", entry.position.y),
                String(format: "%.2f", entry.speed),
                entry.line
            ]
            rows.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    init(
        speed: Float = 2,
        speedStep: Float = 1,
        speedIncreaseInterval: TimeInterval = 10,
        heartbeatInterval: TimeInterval = 1,
        turnDistance: ClosedRange<Float> = 1.5...4.5,
        maxSpeed: Float = .infinity,
        persistsLog: Bool = true
    ) {
        self.speed = speed
        self.initialSpeed = speed
        self.speedStep = speedStep
        self.speedIncreaseInterval = speedIncreaseInterval
        self.heartbeatInterval = heartbeatInterval
        self.turnDistance = turnDistance
        self.maxSpeed = maxSpeed
        self.persistsLog = persistsLog
    }

    /// Starts the object inside the 10×10 box. `halfExtents` is for tests that need a smaller box.
    func start(at now: Date = .now, halfExtents: SIMD2<Float>? = nil) {
        guard !isRunning else { return }
        if let halfExtents {
            center = .zero
            self.halfExtents = halfExtents
            edgeMargin = 0.05
            position = clampInside(SIMD2(-min(0.45, halfExtents.x * 0.5), 0))
        } else {
            center = SIMD2(5, 5)
            self.halfExtents = Self.boxSize * 0.5
            edgeMargin = 0.45
            position = clampInside(SIMD2(2, 5))
        }
        direction = .right
        speed = initialSpeed
        trail = []
        lastHeartbeat = now
        distanceToTurn = Float.random(in: turnDistance)
        nextSpeedIncrease = now.addingTimeInterval(speedIncreaseInterval)
        isRunning = true
        record(.session, at: now)
        record(.started, at: now)
    }

    func stop(at now: Date = .now) {
        guard isRunning else { return }
        record(.stopped, at: now)
        isRunning = false
    }

    /// Clears the recorded session. The text file keeps earlier sessions.
    func resetSession() {
        isRunning = false
        speed = initialSpeed
        log.removeAll()
        trail.removeAll()
        origin = nil
    }

    /// Writes a protocol marker (phase start/end, rating, sync point) into the same timeline.
    func mark(_ label: String, at now: Date = .now) {
        record(.marker, note: label, at: now)
    }

    func tick(deltaTime: TimeInterval, now: Date) {
        guard isRunning else { return }
        var remaining = max(deltaTime, 0)
        var time = now.addingTimeInterval(-remaining)
        var steps = 0

        while remaining > 0.0001 && steps < 64 {
            steps += 1
            let timeToHeartbeat = max(0, heartbeatInterval - time.timeIntervalSince(lastHeartbeat))
            let timeToTurn = TimeInterval(max(0, distanceToTurn) / max(speed, 0.01))
            let timeToSpeedIncrease = max(0, nextSpeedIncrease.timeIntervalSince(time))
            let runway = max(0, room(along: direction))
            let timeToWall = TimeInterval(runway / max(speed, 0.01))
            let slice = min(remaining, timeToHeartbeat, timeToTurn, timeToSpeedIncrease, timeToWall)

            if slice > 0.00001 {
                let step: Float = speed * Float(slice)
                position += direction.vector * step
                distanceToTurn -= step
                position = clampToBounds(position)
                rememberPosition()
                time = time.addingTimeInterval(slice)
                remaining -= slice
            }

            if room(along: direction) <= 0.02 {
                let before = direction
                changeDirection(reason: .edge, at: time)
                if direction == before {
                    position -= before.vector * 0.05
                    position = clampInside(position)
                    break
                }
                continue
            }

            if distanceToTurn <= 0.001 {
                changeDirection(reason: .timer, at: time)
                continue
            }

            let heartbeatDue = time.timeIntervalSince(lastHeartbeat) >= heartbeatInterval - 0.001
            let speedDue = nextSpeedIncrease.timeIntervalSince(time) <= 0.001
            if heartbeatDue {
                record(.moving, at: time)
                lastHeartbeat = time
            }
            if speedDue {
                increaseSpeed(at: time)
            }
            if heartbeatDue || speedDue {
                continue
            }

            if slice <= 0.00001 {
                break
            }
        }
    }

    private func increaseSpeed(at time: Date) {
        let previous = speed
        speed = min(speed + speedStep, maxSpeed)
        nextSpeedIncrease = time.addingTimeInterval(speedIncreaseInterval)
        record(.increasedSpeed, previousSpeed: previous, at: time)
    }

    private func changeDirection(reason: TurnReason, at time: Date) {
        let previous = direction
        let newDirection = nextDirection()
        guard newDirection != previous else {
            distanceToTurn = Float.random(in: turnDistance)
            return
        }
        direction = newDirection
        // After bouncing off a wall the snake is running along it; turn back inward soon
        // so it explores the whole board instead of tracing the edge.
        let hugsWall = room(along: newDirection.clockwise) < 1 || room(along: newDirection.counterClockwise) < 1
        distanceToTurn = reason == .edge && hugsWall
            ? Float.random(in: 0.6...max(0.6, turnDistance.lowerBound))
            : Float.random(in: turnDistance)
        lastHeartbeat = time
        record(.changedDirection, previous: previous, turnReason: reason, at: time)
    }

    /// Picks a new direction at random. A turn leaves the current axis when it can (no reversing
    /// along the same line), and directions with more open space are more likely, which pulls
    /// the snake toward the middle instead of letting it circle the edge.
    private func nextDirection() -> MoveDirection {
        let turns = MoveDirection.allCases.filter { candidate in
            candidate != direction
                && candidate != direction.opposite
                && room(along: candidate) > minimumRunway
        }
        if let turn = weightedByRoom(turns) {
            return turn
        }

        let anywhere = MoveDirection.allCases.filter { candidate in
            candidate != direction && room(along: candidate) > minimumRunway
        }
        if let turn = anywhere.randomElement() {
            return turn
        }
        return direction.opposite
    }

    private func weightedByRoom(_ candidates: [MoveDirection]) -> MoveDirection? {
        guard !candidates.isEmpty else { return nil }
        let weights: [Float] = candidates.map { room(along: $0) }
        let total: Float = weights.reduce(0, +)
        guard total > 0 else { return candidates.randomElement() }
        var pick: Float = Float.random(in: 0..<total)
        for (candidate, weight) in zip(candidates, weights) {
            if pick < weight { return candidate }
            pick -= weight
        }
        return candidates.last
    }

    private func room(along direction: MoveDirection) -> Float {
        switch direction {
        case .right: (center.x + halfExtents.x) - position.x
        case .left: position.x - (center.x - halfExtents.x)
        case .up: (center.y + halfExtents.y) - position.y
        case .down: position.y - (center.y - halfExtents.y)
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func clampToBounds(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(
            min(max(point.x, center.x - halfExtents.x), center.x + halfExtents.x),
            min(max(point.y, center.y - halfExtents.y), center.y + halfExtents.y)
        )
    }

    private func clampInside(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let margin = edgeMargin
        return SIMD2(
            min(max(point.x, center.x - halfExtents.x + margin), center.x + halfExtents.x - margin),
            min(max(point.y, center.y - halfExtents.y + margin), center.y + halfExtents.y - margin)
        )
    }

    private func rememberPosition() {
        if let last = trail.last, simd_distance(last, position) < 0.35 {
            return
        }
        trail.append(position)
        if trail.count > Self.maxTrailCount {
            trail.removeFirst(trail.count - Self.maxTrailCount)
        }
    }

    private func record(
        _ kind: MovementEventKind,
        previous: MoveDirection? = nil,
        previousSpeed: Float? = nil,
        turnReason: TurnReason? = nil,
        note: String? = nil,
        at now: Date
    ) {
        if origin == nil { origin = now }
        let line = makeLine(kind: kind, previous: previous, previousSpeed: previousSpeed, turnReason: turnReason, note: note, at: now)
        let entry = MovementLogEntry(
            id: UUID(),
            timestamp: now,
            kind: kind,
            direction: direction,
            previousDirection: previous,
            position: position,
            speed: speed,
            elapsed: now.timeIntervalSince(origin ?? now),
            note: note,
            line: line
        )
        log.append(entry)
        if log.count > 50_000 {
            log.removeFirst(log.count - 50_000)
        }
        movementLogger.info("\(line, privacy: .public)")
        if persistsLog {
            MovementLogFile.append(line)
        }
    }

    private func makeLine(
        kind: MovementEventKind,
        previous: MoveDirection?,
        previousSpeed: Float?,
        turnReason: TurnReason?,
        note: String?,
        at now: Date
    ) -> String {
        let time = LogClock.string(from: now)
        let place = String(format: "at (%.2f, %.2f)", position.x, position.y)
        switch kind {
        case .session:
            return "---------- session \(time) ----------"
        case .started:
            return "\(time)  started moving \(direction.rawValue)  \(place)"
        case .moving:
            return "\(time)  moving \(direction.rawValue)  \(place)"
        case .changedDirection:
            let from = previous?.rawValue ?? "unknown"
            let why = turnReason?.rawValue ?? "turn"
            return "\(time)  changed direction  \(from) → \(direction.rawValue)  (\(why))  \(place)"
        case .increasedSpeed:
            let from = speedText(previousSpeed ?? speed - speedStep)
            return "\(time)  speed changed from \(from) to \(speedText(speed))"
        case .stopped:
            return "\(time)  stopped  last direction \(direction.rawValue)  \(place)"
        case .marker:
            return "\(time)  [marker] \(note ?? "")"
        }
    }

    private func speedText(_ value: Float) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
