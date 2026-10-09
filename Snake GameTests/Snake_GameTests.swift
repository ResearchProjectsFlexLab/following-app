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

    @Test func hittingTheEdgeLogsADirectionChange() {
        let game = makeGame()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        game.start(at: start, halfExtents: SIMD2(0.4, 0.4))

        game.tick(deltaTime: 2, now: start.addingTimeInterval(2))

        let change = game.log.last { $0.kind == .changedDirection }
        #expect(change?.previousDirection == .right)
        #expect(change?.direction != .right)
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
