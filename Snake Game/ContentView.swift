//
//  ContentView.swift
//  Snake Game
//
//  Created by Prisha Marpu on 10/2/26.
//

import Foundation
import SwiftUI

/// The small control window: one button to start, and a "saved" screen at the end.
/// The game itself plays in the immersive space.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var notice: String?

    private var session: SessionController { appModel.session }

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                StartView(
                    seconds: Binding(get: { session.taskSeconds }, set: { session.taskSeconds = $0 }),
                    isOpening: appModel.isOpeningSpace,
                    start: { Task { await start() } },
                    playInWindow: playInWindow
                )
            case .countdown, .task:
                WindowGameView()
            case .complete:
                DoneView(newTest: { session.reset() })
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
        .onAppear { appModel.controlWindowIsOpen = true }
        .onDisappear { appModel.controlWindowIsOpen = false }
        #if DEBUG
        // Simulator smoke test: launch with `-autostart` to run a session hands-free.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-autostart"), session.phase == .idle else { return }
            await start()
        }
        #endif
    }

    private func start() async {
        notice = nil
        session.runsImmersive = true
        // ImmersiveView begins the session when it appears, so a slow
        // openImmersiveSpace call can't leave Start doing nothing.
        appModel.isOpeningSpace = true
        let result = await openImmersiveSpace(id: AppModel.immersiveSpaceID)
        if result != .opened, appModel.isOpeningSpace {
            notice = "Couldn't open the immersive view, so the game is playing here instead."
            playInWindow()
        }
    }

    private func playInWindow() {
        appModel.isOpeningSpace = false
        session.runsImmersive = false
        session.begin()
    }
}

// MARK: - Start

private struct StartView: View {
    @Binding var seconds: Int
    let isOpening: Bool
    let start: () -> Void
    let playInWindow: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.pulse, isActive: isOpening)

            VStack(spacing: 8) {
                Text("Follow the Snake")
                    .font(.extraLargeTitle2)
                Text("Sit comfortably and keep your eyes on the snake.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("It speeds up every 10 seconds and saves itself when it's done.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(SessionController.durationOptions, id: \.self) { option in
                    let selected = option == seconds
                    Button {
                        seconds = option
                    } label: {
                        Text("\(option / 60) min")
                            .font(.title3.weight(selected ? .bold : .regular))
                            .frame(width: 96)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selected ? .green : nil)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .disabled(isOpening)

            if isOpening {
                VStack(spacing: 14) {
                    ProgressView("Getting ready…")
                    Button("Play in this window instead", action: playInWindow)
                        .buttonStyle(.borderless)
                        .font(.footnote)
                }
            } else {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 36)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

// MARK: - Fallback: game in the window

private struct WindowGameView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let session = appModel.session
        VStack(spacing: 16) {
            FlatBox(game: session.game, showsTarget: session.phase == .task)
                .overlay {
                    if session.phase == .countdown {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            Text("\(Int(session.remaining(at: context.date).rounded(.up)))")
                                .font(.system(size: 120, weight: .bold, design: .rounded))
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                }
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                ProgressView(value: session.phase == .task ? session.progress(at: context.date) : 0)
                    .tint(.green)
            }
            Button("Stop", role: .destructive) {
                session.abort(reason: "stopped_in_window")
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Done

private struct DoneView: View {
    @Environment(AppModel.self) private var appModel
    let newTest: () -> Void

    var body: some View {
        let session = appModel.session
        VStack(spacing: 26) {
            Text(session.wasAborted ? "Test Stopped" : "Test Complete")
                .font(.largeTitle.weight(.bold))

            HStack(spacing: 0) {
                StatCell(value: clock(session.taskDuration), label: "Duration", color: .green)
                Divider().frame(height: 44)
                StatCell(value: "\(session.turnCount)", label: "Turns", color: .white)
                Divider().frame(height: 44)
                StatCell(value: String(format: "%.1f", session.topSpeed), label: "Top speed", color: .cyan)
            }
            .padding(.vertical, 12)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 420)

            VStack(spacing: 6) {
                if let error = session.saveError {
                    Label("Log not saved", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let file = session.logFile {
                    Label("Log saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text("Files › On My Apple Vision Pro › Snake Game")
                        .font(.footnote)
                    Text(file.lastPathComponent)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            Button(action: newTest) {
                Label("New Test", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 2D board (fallback only)

private struct FlatBox: View {
    let game: FollowGame
    let showsTarget: Bool

    var body: some View {
        let objectPosition = game.position
        let trail = game.trail
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            context.fill(Path(roundedRect: rect, cornerRadius: 16), with: .color(Color(red: 0.05, green: 0.07, blue: 0.12)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 16), with: .color(.cyan.opacity(0.8)), lineWidth: 3)
            guard showsTarget else { return }

            let minCorner = game.boundsMin
            let span = game.boundsMax - minCorner
            func point(_ position: SIMD2<Float>) -> CGPoint {
                CGPoint(
                    x: rect.minX + CGFloat((position.x - minCorner.x) / span.x) * side,
                    y: rect.maxY - CGFloat((position.y - minCorner.y) / span.y) * side
                )
            }
            for (index, sample) in trail.enumerated() {
                let fade = CGFloat(index + 1) / CGFloat(trail.count + 1)
                let radius = 5 + fade * 7
                let center = point(sample)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.green.opacity(0.3 + 0.5 * fade))
                )
            }
            let head = point(objectPosition)
            context.fill(Path(ellipseIn: CGRect(x: head.x - 15, y: head.y - 15, width: 30, height: 30)), with: .color(.green))
        }
        .frame(minHeight: 300)
        .accessibilityLabel("Snake game board")
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
