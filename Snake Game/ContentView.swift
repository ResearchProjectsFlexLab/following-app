//
//  ContentView.swift
//  Snake Game
//
//  Created by Prisha Marpu on 10/2/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var lastTick: Date?
    @State private var exportText = ""
    @State private var showExporter = false
    @State private var saveNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Follow the Snake")
                .font(.largeTitle)

            Text("Speed starts at 2 and increases by 1 every 5 seconds. Each increase is written to the log.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(speedText)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("increases every 5 seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusItem(title: "Direction", value: directionText)
                Button("Reset") {
                    lastTick = nil
                    appModel.game.resetSession()
                    saveNotice = nil
                }
                .disabled(appModel.game.log.isEmpty && !appModel.game.isRunning)
            }

            FlatBox(game: appModel.game)
                .frame(maxWidth: .infinity)
                .frame(height: 360)

            logPanel
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        step(to: date)
                    }
            }
        }
        .onAppear {
            guard !appModel.game.isRunning else { return }
            let now = Date()
            lastTick = now
            appModel.game.start(at: now)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: LogFile(text: exportText),
            contentType: .plainText,
            defaultFilename: "snake-movement-log"
        ) { result in
            switch result {
            case .success:
                saveNotice = "Log saved."
            case .failure(let error):
                let nsError = error as NSError
                let cancelled = nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue
                if !cancelled {
                    saveNotice = "Could not save the log."
                }
            }
        }
    }

    private var directionText: String {
        appModel.game.log.isEmpty ? "—" : appModel.game.direction.rawValue
    }

    private var speedText: String {
        String(format: "%.0f", appModel.game.speed)
    }

    private func step(to date: Date) {
        if !appModel.game.isRunning {
            lastTick = date
            appModel.game.start(at: date)
            return
        }
        let delta = lastTick.map { min(date.timeIntervalSince($0), 0.05) } ?? 0
        lastTick = date
        guard delta > 0 else { return }
        appModel.game.tick(deltaTime: delta, now: date)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Session log")
                    .font(.headline)
                Spacer()
                Text("\(appModel.game.log.count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Written each time the speed increases.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: beginExport) {
                Label("Download log", systemImage: "arrow.down.doc")
            }
            .disabled(appModel.game.log.isEmpty)

            if let saveNotice {
                Text(saveNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            logList
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func beginExport() {
        guard !appModel.game.log.isEmpty else { return }
        exportText = appModel.game.logText
        showExporter = true
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if appModel.game.log.isEmpty {
                        Text("The log starts as soon as the object moves.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.game.log) { entry in
                            Text(entry.line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: appModel.game.log.count) { _, _ in
                guard let last = appModel.game.log.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for kind: MovementEventKind) -> Color {
        switch kind {
        case .moving:
            .secondary
        case .increasedSpeed:
            .orange
        case .session, .started, .changedDirection, .stopped:
            .primary
        }
    }
}

private struct FlatBox: View {
    let game: FollowGame

    var body: some View {
        let objectPosition = game.position
        let trail = game.trail
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(
                x: (size.width - side) / 2,
                y: (size.height - side) / 2,
                width: side,
                height: side
            )

            context.fill(
                Path(roundedRect: rect, cornerRadius: 12),
                with: .color(Color(red: 0.08, green: 0.1, blue: 0.14))
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 12),
                with: .color(.cyan),
                lineWidth: 4
            )

            let minCorner = game.boundsMin
            let span = game.boundsMax - minCorner
            func point(_ position: SIMD2<Float>) -> CGPoint {
                let nx = CGFloat((position.x - minCorner.x) / span.x)
                let ny = CGFloat((position.y - minCorner.y) / span.y)
                return CGPoint(
                    x: rect.minX + nx * side,
                    y: rect.maxY - ny * side
                )
            }

            for (index, sample) in trail.enumerated() {
                let fade = CGFloat(index + 1) / CGFloat(trail.count + 1)
                let radius = 5 + fade * 6
                let center = point(sample)
                let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(.green.opacity(0.35 + 0.4 * fade)))
            }

            let head = point(objectPosition)
            let radius: CGFloat = 14
            let dot = CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(.orange))
        }
        .accessibilityLabel("10 by 10 box")
    }
}

nonisolated struct LogFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct StatusItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
