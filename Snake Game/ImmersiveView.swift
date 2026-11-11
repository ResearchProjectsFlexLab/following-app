//
//  ImmersiveView.swift
//  Snake Game
//
//  Full immersion under a starry night sky. During the rests the participant sits by a moonlit
//  lake (LakeScene); during the game the lake fades to a glowing grid floor and a board
//  ~2.4 m away (about 35° wide) where they follow a glowing 3D snake.
//

import ARKit
import CoreGraphics
import QuartzCore
import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var stage = TrackingStage()

    /// WindowGroup.openWindow makes a new window each call, so only open one if none is showing.
    private func showControlWindow() {
        guard !appModel.controlWindowIsOpen else { return }
        appModel.controlWindowIsOpen = true
        openWindow(id: AppModel.controlWindowID)
    }

    var body: some View {
        RealityView { content in
            stage.attachHUD(session: appModel.session)
            content.add(stage.root)
            // Sync every rendered frame rather than relying on SwiftUI observation.
            stage.updates = content.subscribe(to: SceneEvents.Update.self) { _ in
                stage.sync(with: appModel.session)
            }
        }
        .task { await stage.headTracker.start() }
        .persistentSystemOverlays(.hidden)
        .upperLimbVisibility(.visible)
        .onAppear {
            appModel.immersiveSpaceIsOpen = true
            if appModel.isOpeningSpace {
                appModel.isOpeningSpace = false
                appModel.session.begin()
                // Nothing should float between the participant and the scene.
                dismissWindow(id: AppModel.controlWindowID)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-autostart") {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        appModel.session.startBaseline()
                    }
                }
                #endif
            } else if !(appModel.session.isActive && appModel.session.runsImmersive) {
                // Opened without a session (e.g. restored by the system): don't trap the participant in it.
                Task { await dismissImmersiveSpace() }
            }
        }
        .onDisappear {
            appModel.immersiveSpaceIsOpen = false
            // Pressing the Digital Crown ends the session early; what was recorded is still saved.
            if appModel.session.isActive, appModel.session.runsImmersive {
                appModel.session.abort(reason: "exited_immersive")
            }
            showControlWindow()
        }
        .onChange(of: appModel.session.phase) { _, phase in
            if phase == .complete {
                showControlWindow()
                Task { await dismissImmersiveSpace() }
            }
        }
    }
}

@MainActor
final class TrackingStage {
    /// 1.5 m at 2.4 m away is about 35° wide: real eye movement without craning the neck.
    static let boardSize: Float = 1.5
    /// Centered at seated eye height, in meters from the floor origin.
    static let boardPosition = SIMD3<Float>(0, 1.2, -2.4)
    static let bodySegments = 48
    static let segmentSpacing: Float = 0.018

    let root = Entity()
    var updates: EventSubscription?
    let headTracker = HeadTracker()
    private var lastHeadSample: Date = .distantPast

    private let board = Entity()
    /// Board, glow and grid floor: shown for the countdown and the game.
    private let gameGroup = Entity()
    private let lake = LakeScene()
    private let instructions = Entity()
    private let restHUD = Entity()
    private var lastSync: Date?
    private let head: ModelEntity
    private let halo: ModelEntity
    private var body: [ModelEntity] = []
    private var path: [SIMD3<Float>] = []
    private let countdownHUD = Entity()
    private let progressHUD = Entity()
    private let startTime = Date()
    private var lastPhase: SessionPhase = .idle

    init() {
        let size = Self.boardSize

        // Night sky dome and stars.
        let dome = ModelEntity(mesh: .generateSphere(radius: 60), materials: [Self.skyMaterial()])
        dome.scale = SIMD3(-1, 1, 1)
        root.addChild(dome)
        root.addChild(Self.makeStars(count: 700, radius: 30))

        // Glowing grid floor that fades out with distance.
        if let floorTexture = Self.texture(size: 1024, draw: Self.drawFloorGrid) {
            let floor = ModelEntity(
                mesh: .generatePlane(width: 16, depth: 16),
                materials: [Self.unlit(texture: floorTexture)]
            )
            floor.position.y = 0.001
            gameGroup.addChild(floor)
        }

        board.position = Self.boardPosition
        gameGroup.addChild(board)
        gameGroup.components.set(OpacityComponent(opacity: 0))
        gameGroup.isEnabled = false
        root.addChild(gameGroup)

        lake.root.components.set(OpacityComponent(opacity: 0))
        root.addChild(lake.root)

        instructions.position = [0, 1.15, -1.6]
        root.addChild(instructions)
        restHUD.position = [0, 0.95, -2.6]
        root.addChild(restHUD)

        // Soft cyan glow behind the board.
        if let glowTexture = Self.texture(size: 256, draw: Self.drawRadialGlow) {
            let glow = ModelEntity(
                mesh: .generatePlane(width: size * 1.9, height: size * 1.9),
                materials: [Self.unlit(texture: glowTexture)]
            )
            glow.position.z = -0.03
            board.addChild(glow)
        }

        let rim = ModelEntity(
            mesh: .generatePlane(width: size + 0.04, height: size + 0.04, cornerRadius: 0.06),
            materials: [Self.unlit(color: UIColor(red: 0.3, green: 0.95, blue: 1, alpha: 1), opacity: 0.9)]
        )
        board.addChild(rim)
        let faceMaterial: UnlitMaterial = Self.texture(size: 1024, draw: Self.drawBoardFace)
            .map { Self.unlit(texture: $0) }
            ?? Self.unlit(color: UIColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1))
        let face = ModelEntity(
            mesh: .generatePlane(width: size, height: size, cornerRadius: 0.05),
            materials: [faceMaterial]
        )
        face.position.z = 0.002
        board.addChild(face)

        // The snake: a bright head with a halo, and a tapering glowing body that follows its path.
        for index in 0..<Self.bodySegments {
            let t: Float = Float(index) / Float(Self.bodySegments - 1)  // 0 near head, 1 at tail
            let ct: CGFloat = CGFloat(t)
            let red: CGFloat = 0.35 - 0.25 * ct
            let green: CGFloat = 1.0 - 0.25 * ct
            let blue: CGFloat = 0.45 + 0.4 * ct
            let color = UIColor(red: red, green: green, blue: blue, alpha: 1)
            let radius: Float = 0.032 - 0.02 * t
            let opacity: Float = 0.95 - 0.7 * t
            let segment = ModelEntity(
                mesh: .generateSphere(radius: radius),
                materials: [Self.unlit(color: color, opacity: opacity)]
            )
            segment.isEnabled = false
            board.addChild(segment)
            body.append(segment)
        }
        head = ModelEntity(
            mesh: .generateSphere(radius: 0.042),
            materials: [Self.unlit(color: UIColor(red: 0.75, green: 1, blue: 0.55, alpha: 1))]
        )
        halo = ModelEntity(
            mesh: .generateSphere(radius: 0.085),
            materials: [Self.unlit(color: UIColor(red: 0.5, green: 1, blue: 0.5, alpha: 1), opacity: 0.18)]
        )
        head.addChild(halo)
        head.isEnabled = false
        board.addChild(head)

        countdownHUD.position = [0, 0, 0.08]
        board.addChild(countdownHUD)
        progressHUD.position = [0, size / 2 + 0.1, 0]
        board.addChild(progressHUD)
    }

    func attachHUD(session: SessionController) {
        countdownHUD.components.set(ViewAttachmentComponent(rootView: CountdownHUD(session: session)))
        progressHUD.components.set(ViewAttachmentComponent(rootView: ProgressHUD(session: session)))
        instructions.components.set(ViewAttachmentComponent(rootView: BaselineInstructionsCard(session: session)))
        restHUD.components.set(ViewAttachmentComponent(rootView: RestHUD(session: session)))
    }

    func sync(with session: SessionController) {
        let phase = session.phase
        let now = Date()
        let dt: Float = Float(min(0.1, now.timeIntervalSince(lastSync ?? now)))
        lastSync = now
        if phase != lastPhase {
            if phase == .task { path.removeAll() }
            lastPhase = phase
        }

        // The lake shows for the instructions and both rests; the game scene for the countdown and game.
        let showsGame = phase == .countdown || phase == .task
        Self.fade(gameGroup, toward: showsGame ? 1 : 0, dt: dt)
        Self.fade(lake.root, toward: showsGame ? 0 : 1, dt: dt)
        if lake.root.isEnabled { lake.update(session: session, now: now) }
        instructions.isEnabled = phase == .ready
        restHUD.isEnabled = phase.isRest

        countdownHUD.isEnabled = phase == .countdown
        progressHUD.isEnabled = phase == .task
        head.isEnabled = phase == .task

        if phase.isRest {
            recordHead(target: LakeScene.fixationPoint, session: session)
        }

        guard phase == .task else {
            body.forEach { $0.isEnabled = false }
            return
        }

        let game = session.game
        let position = point(game.position, in: game, z: 0.04)
        head.position = position
        recordHead(target: Self.boardPosition + position, session: session)
        let seconds: Float = Float(Date().timeIntervalSince(startTime))
        let pulse: Float = 1 + 0.15 * sin(seconds * 5)
        halo.scale = SIMD3<Float>(repeating: pulse)

        if let last = path.last {
            if simd_distance(last, position) >= Self.segmentSpacing {
                path.append(position)
            }
        } else {
            path.append(position)
        }
        let maxPath = Self.bodySegments + 2
        if path.count > maxPath { path.removeFirst(path.count - maxPath) }

        for (index, segment) in body.enumerated() {
            let pathIndex = path.count - 2 - index
            if pathIndex >= 0 {
                segment.isEnabled = true
                var p = path[pathIndex]
                p.z = 0.03
                segment.position = p
            } else {
                segment.isEnabled = false
            }
        }
    }

    /// Fades an entity's opacity toward a target over about two-thirds of a second, hiding it at zero.
    private static func fade(_ entity: Entity, toward target: Float, dt: Float) {
        let current: Float = entity.components[OpacityComponent.self]?.opacity ?? 1
        let step: Float = dt * 1.5
        let next: Float = current < target ? min(target, current + step) : max(target, current - step)
        entity.components.set(OpacityComponent(opacity: next))
        entity.isEnabled = next > 0.001
    }

    /// About 20 samples per second of where the head points, compared with where it should be looking
    /// (the snake during the game, the moon's reflection during the rests).
    private func recordHead(target: SIMD3<Float>, session: SessionController) {
        let now = Date()
        guard now.timeIntervalSince(lastHeadSample) >= 0.05, let pose = headTracker.pose() else { return }
        lastHeadSample = now
        let c3 = pose.columns.3
        let c2 = pose.columns.2
        let headPosition = SIMD3<Float>(c3.x, c3.y, c3.z)
        let forward: SIMD3<Float> = simd_normalize(SIMD3<Float>(-c2.x, -c2.y, -c2.z))
        let toSnake: SIMD3<Float> = simd_normalize(target - headPosition)
        let cosine: Float = min(1, max(-1, simd_dot(forward, toSnake)))
        let degrees: Float = 180 / Float.pi
        let offTarget: Float = acos(cosine) * degrees
        let yaw: Float = atan2(-forward.x, -forward.z) * degrees
        let pitch: Float = asin(forward.y) * degrees
        session.recordHead(HeadSample(
            time: now, phase: session.phase, position: headPosition, yawDegrees: yaw, pitchDegrees: pitch, offTargetDegrees: offTarget
        ))
    }

    private func point(_ position: SIMD2<Float>, in game: FollowGame, z: Float) -> SIMD3<Float> {
        let span: SIMD2<Float> = game.boundsMax - game.boundsMin
        let offset: SIMD2<Float> = position - game.boundsMin
        let normalized: SIMD2<Float> = offset / span - SIMD2<Float>(repeating: 0.5)
        let scaled: SIMD2<Float> = normalized * Self.boardSize
        return SIMD3<Float>(scaled.x, scaled.y, z)
    }

    // MARK: - Environment building

    private static func makeStars(count: Int, radius: Float) -> Entity {
        let container = Entity()
        let mesh = MeshResource.generateSphere(radius: 1)
        let palette = [
            unlit(color: .white),
            unlit(color: UIColor(red: 0.75, green: 0.85, blue: 1, alpha: 1)),
            unlit(color: UIColor(red: 1, green: 0.92, blue: 0.75, alpha: 1)),
        ]
        var generator = SystemRandomNumberGenerator()
        var placed = 0
        while placed < count {
            // Uniform direction on a sphere, kept above the floor.
            let z: Float = Float.random(in: -1...1, using: &generator)
            guard z > -0.05 else { continue }
            let angle: Float = Float.random(in: 0..<(2 * Float.pi), using: &generator)
            let r: Float = (1 - z * z).squareRoot()
            let x: Float = r * cos(angle)
            let y: Float = r * sin(angle)
            let direction = SIMD3<Float>(x, z, y)
            let star = ModelEntity(mesh: mesh, materials: [palette[Int.random(in: 0..<palette.count, using: &generator)]])
            star.position = direction * radius
            let starSize: Float = Float.random(in: 0.025...0.07, using: &generator)
            star.scale = SIMD3<Float>(repeating: starSize)
            container.addChild(star)
            placed += 1
        }
        return container
    }

    private static func skyMaterial() -> UnlitMaterial {
        guard let texture = texture(size: 512, draw: { ctx, size in
            // Dark at the zenith and below the floor, a faint teal glow at the horizon.
            let colors = [
                CGColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1),
                CGColor(red: 0.03, green: 0.05, blue: 0.13, alpha: 1),
                CGColor(red: 0.04, green: 0.14, blue: 0.20, alpha: 1),
                CGColor(red: 0.03, green: 0.05, blue: 0.13, alpha: 1),
                CGColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1),
            ] as CFArray
            let locations: [CGFloat] = [0, 0.3, 0.5, 0.7, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
            }
        }) else {
            return unlit(color: UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1))
        }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    private static func drawFloorGrid(_ ctx: CGContext, _ size: CGFloat) {
        let cells: Int = 32
        let pieces: Int = 32
        let step: CGFloat = size / CGFloat(cells)
        let piece: CGFloat = size / CGFloat(pieces)
        let half: CGFloat = size / 2
        ctx.setLineWidth(2)
        for i in 0...cells {
            let line: CGFloat = CGFloat(i) * step
            // Draw each line in short pieces so it fades with distance from the participant.
            for p in 0..<pieces {
                let from: CGFloat = CGFloat(p) * piece
                let to: CGFloat = from + piece
                let along: CGFloat = (from + to) / 2 - half
                let across: CGFloat = line - half
                let distance: CGFloat = (along * along + across * across).squareRoot() / half
                let fade: CGFloat = 1 - distance * distance
                let alpha: CGFloat = fade > 0 ? 0.55 * fade : 0
                ctx.setStrokeColor(CGColor(red: 0.3, green: 0.9, blue: 1, alpha: alpha))
                // Vertical piece.
                ctx.move(to: CGPoint(x: line, y: from))
                ctx.addLine(to: CGPoint(x: line, y: to))
                // Horizontal piece.
                ctx.move(to: CGPoint(x: from, y: line))
                ctx.addLine(to: CGPoint(x: to, y: line))
                ctx.strokePath()
            }
        }
    }

    private static func drawRadialGlow(_ ctx: CGContext, _ size: CGFloat) {
        let colors = [
            CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 0.35),
            CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 0),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            let center = CGPoint(x: size / 2, y: size / 2)
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
        }
    }

    private static func drawBoardFace(_ ctx: CGContext, _ size: CGFloat) {
        ctx.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 0.94))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // 10 × 10 grid matching the game's box.
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.85, blue: 1, alpha: 0.12))
        ctx.setLineWidth(2)
        for i in 1..<10 {
            let offset = size * CGFloat(i) / 10
            ctx.move(to: CGPoint(x: offset, y: 0))
            ctx.addLine(to: CGPoint(x: offset, y: size))
            ctx.move(to: CGPoint(x: 0, y: offset))
            ctx.addLine(to: CGPoint(x: size, y: offset))
        }
        ctx.strokePath()
    }

    // MARK: - Material helpers

    static func texture(size: Int, draw: (CGContext, CGFloat) -> Void) -> TextureResource? {
        texture(width: size, height: size) { ctx, width, _ in draw(ctx, width) }
    }

    static func texture(width: Int, height: Int, draw: (CGContext, CGFloat, CGFloat) -> Void) -> TextureResource? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(ctx, CGFloat(width), CGFloat(height))
        guard let image = ctx.makeImage() else { return nil }
        return try? TextureResource(image: image, withName: nil, options: .init(semantic: .color))
    }

    static func unlit(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }

    static func unlit(color: UIColor, opacity: Float = 1) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return material
    }
}

/// Reads the headset's position and direction. Works on the device; the simulator has no world tracking.
@MainActor
final class HeadTracker {
    private let session = ARKitSession()
    private let world = WorldTrackingProvider()
    private var isRunning = false

    func start() async {
        guard WorldTrackingProvider.isSupported, !isRunning else { return }
        do {
            try await session.run([world])
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func pose() -> simd_float4x4? {
        guard isRunning, world.state == .running,
              let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return anchor.originFromAnchorTransform
    }
}

/// Big 3-2-1 in the middle of the board before the snake appears.
private struct CountdownHUD: View {
    let session: SessionController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(spacing: 6) {
                Text("\(max(1, Int(session.remaining(at: context.date).rounded(.up))))")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(session.remaining(at: context.date).rounded(.up)))
                Text("Follow the snake with your eyes")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
    }
}

/// A slim, unobtrusive progress bar above the board while the snake runs.
private struct ProgressHUD: View {
    let session: SessionController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            ProgressView(value: session.progress(at: context.date))
                .tint(.green)
                .frame(width: 600)
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .glassBackgroundEffect(in: .capsule)
                .opacity(0.8)
        }
    }
}
