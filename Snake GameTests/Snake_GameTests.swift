//
//  Snake_GameTests.swift
//  Snake GameTests
//
//  Created by Prisha Marpu on 10/2/26.
//

import Foundation
import Testing
import simd
@testable import Snake_Game

@MainActor
struct Snake_GameTests {

    @Test func objectStaysInsideTheTenByTenBox() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start)

        #expect(FollowGame.boxSize == SIMD2<Float>(10, 10))
        #expect(isInside(game.position, game: game))

        game.tick(deltaTime: 2, now: start.addingTimeInterval(2))
        #expect(isInside(game.position, game: game))
    }

    @Test func directionsAreTheFourFlatAxes() {
        #expect(MoveDirection.up.vector == SIMD2<Float>(0, 1))
        #expect(MoveDirection.down.vector == SIMD2<Float>(0, -1))
        #expect(MoveDirection.left.vector == SIMD2<Float>(-1, 0))
        #expect(MoveDirection.right.vector == SIMD2<Float>(1, 0))
        #expect(MoveDirection.allCases.count == 4)
    }

    @Test func sessionLogsInitialDirectionWithTimestamp() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))

        let started = game.log.first { $0.kind == .started }
        #expect(started?.direction == .right)
        #expect(started?.timestamp == start)
        #expect(started?.line.hasPrefix(LogClock.string(from: start)) == true)
        #expect(started?.line.contains("started moving right") == true)
    }

    @Test func downloadedLogContainsEveryMovementThatWasRecorded() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))

        let text = game.logText
        #expect(text.contains("Snake Game log"))
        #expect(text.contains("Entries: \(game.log.count)"))
        #expect(text.contains("started moving right"))
        #expect(text.contains(LogClock.string(from: start)))
    }

    @Test func csvExportCanBeSavedWithTimestamps() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))

        let csv = game.csvText
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "timestamp,event,direction,previous_direction,x,y,message")
        let started = lines.first { $0.contains(",started,right,") }
        #expect(started != nil)
        #expect(started?.contains(LogClock.string(from: start)) == true)
        #expect(started?.contains("started moving right") == true)
    }

    @Test func continuedMovementIsLoggedEverySecond() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))
        let startPosition = game.position

        game.tick(deltaTime: 1, now: start.addingTimeInterval(1))

        let moving = game.log.filter { $0.kind == .moving }
        #expect(moving.count == 1)
        #expect(moving[0].direction == .right)
        #expect(moving[0].line.contains("moving right") == true)
        #expect(moving[0].line.hasPrefix(LogClock.string(from: moving[0].timestamp)) == true)
        #expect(abs(game.position.x - startPosition.x - game.speed) < 0.02)
        #expect(abs(game.position.y - startPosition.y) < 0.02)
    }

    @Test func scheduledTurnLogsTheDirectionChange() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))

        game.tick(deltaTime: 3.2, now: start.addingTimeInterval(3.2))

        let change = game.log.last { $0.kind == .changedDirection }
        #expect(change?.previousDirection == .right)
        #expect(change?.direction == .up)
        #expect(change?.line.contains("changed direction  right → up") == true)
        #expect(change?.line.contains("scheduled turn") == true)
        #expect(change?.line.hasPrefix(LogClock.string(from: change!.timestamp)) == true)
        #expect(game.log.filter { $0.kind == .moving && $0.direction == .right }.count == 3)
    }

    @Test func speedStaysTheSameForTenSecondsThenIncreases() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(10, 10))
        #expect(game.speed == 2)
        #expect(game.speedIncreaseInterval == 10)

        game.tick(deltaTime: 9.9, now: start.addingTimeInterval(9.9))
        #expect(game.speed == 2)
        #expect(game.log.contains { $0.kind == .increasedSpeed } == false)

        game.tick(deltaTime: 0.1, now: start.addingTimeInterval(10))
        #expect(game.speed == 3)
        let firstIncrease = game.log.filter { $0.kind == .increasedSpeed }
        #expect(firstIncrease.count == 1)
        #expect(firstIncrease[0].line.contains("speed increased  2 → 3"))
        #expect(firstIncrease[0].line.hasPrefix(LogClock.string(from: firstIncrease[0].timestamp)))

        game.tick(deltaTime: 10, now: start.addingTimeInterval(20))
        #expect(game.speed == 4)
        let increases = game.log.filter { $0.kind == .increasedSpeed }
        #expect(increases.count == 2)
        #expect(increases[1].line.contains("speed increased  3 → 4"))
        #expect(game.logText.contains("speed increased  2 → 3"))
    }

    @Test func hittingTheEdgeLogsADirectionChange() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(0.4, 0.4))

        game.tick(deltaTime: 2, now: start.addingTimeInterval(2))

        let change = game.log.last { $0.kind == .changedDirection }
        #expect(change?.previousDirection == .right)
        #expect(change?.direction == .left)
        #expect(change?.line.contains("right → left") == true)
        #expect(change?.line.contains("reached the edge") == true)
        #expect(change?.line.hasPrefix(LogClock.string(from: change!.timestamp)) == true)
        #expect(isInside(game.position, game: game))
    }

    private func isInside(_ position: SIMD2<Float>, game: FollowGame) -> Bool {
        position.x >= game.boundsMin.x && position.x <= game.boundsMax.x
            && position.y >= game.boundsMin.y && position.y <= game.boundsMax.y
    }

    private func makeGame() -> FollowGame {
        FollowGame(persistsLog: false)
    }
}
