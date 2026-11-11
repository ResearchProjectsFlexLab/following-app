//
//  LakeScene.swift
//  Snake Game
//
//  The rest scene for the baseline and recovery minutes: a still lake at night with a low moon
//  over a distant ridge of pine-covered hills. Everything is dim, soft-edged and far away
//  (about 12–35 m), so the eyes can relax focus after the close-up tracking task.
//  The moon's glow and slow ripples on the water follow a normal breathing pace.
//

import CoreGraphics
import RealityKit
import SwiftUI

@MainActor
final class LakeScene {
    /// Where the participant is asked to look: the moon's reflection on the water.
    static let fixationPoint = SIMD3<Float>(0, 0, -12)
    /// Beyond the hills (radius 36) and well inside the sky dome (radius 60), about 15° above the horizon.
    static let moonPosition = SIMD3<Float>(0, 10, -37.5)

    let root = Entity()

    private let moonHalo: ModelEntity
    private let reflection: ModelEntity
    private var ripples: [ModelEntity] = []
    private var rippleStarts: [TimeInterval] = []
    private var fireflies: [(entity: ModelEntity, base: SIMD3<Float>, phase: Float)] = []
    private var lastCycle = -1
    private var nextRipple = 0

    init() {
        // Water: a large dark disc that brightens slightly toward the horizon, like a lake reflecting the sky.
        if let texture = TrackingStage.texture(size: 512, draw: Self.drawWater) {
            // Opaque, so it is drawn before the see-through reflection and ripples that sit on it.
            var waterMaterial = UnlitMaterial()
            waterMaterial.color = .init(tint: .white, texture: .init(texture))
            let water = ModelEntity(
                mesh: .generatePlane(width: 76, depth: 76, cornerRadius: 38),
                materials: [waterMaterial]
            )
            water.position.y = 0.002
            root.addChild(water)
        }

        // Distant hills with pine trees all around the lake.
        if let texture = TrackingStage.texture(width: 4096, height: 512, draw: Self.drawRidge),
           let mesh = Self.openCylinder(radius: 36, height: 6, segments: 96) {
            var material = TrackingStage.unlit(texture: texture)
            material.faceCulling = .none
            let ridge = ModelEntity(mesh: mesh, materials: [material])
            root.addChild(ridge)
        }

        // The moon and its soft glow.
        let moon = ModelEntity(
            mesh: .generateSphere(radius: 1.5),
            materials: [TrackingStage.unlit(color: UIColor(red: 0.96, green: 0.95, blue: 0.86, alpha: 1))]
        )
        moon.position = Self.moonPosition
        root.addChild(moon)

        let glowTexture = TrackingStage.texture(size: 256, draw: Self.drawMoonGlow)
        moonHalo = ModelEntity(
            mesh: .generatePlane(width: 14, height: 14),
            materials: [glowTexture.map { TrackingStage.unlit(texture: $0) }
                ?? TrackingStage.unlit(color: .white, opacity: 0.1)]
        )
        moonHalo.position = Self.moonPosition + SIMD3<Float>(0, 0, -0.8)
        moonHalo.components.set(OpacityComponent(opacity: 0.6))
        root.addChild(moonHalo)

        // The moon's reflection: a shimmering path of light on the water toward the participant.
        let streakTexture = TrackingStage.texture(width: 128, height: 1024, draw: Self.drawReflection)
        reflection = ModelEntity(
            mesh: .generatePlane(width: 2.4, depth: 24),
            materials: [streakTexture.map { TrackingStage.unlit(texture: $0) }
                ?? TrackingStage.unlit(color: .white, opacity: 0.2)]
        )
        reflection.position = SIMD3<Float>(0, 0.01, -21)
        reflection.components.set(OpacityComponent(opacity: 0.5))
        root.addChild(reflection)

        // Ripples that spread slowly from the reflection, one per breath.
        if let ringTexture = TrackingStage.texture(size: 512, draw: Self.drawRing) {
            for _ in 0..<3 {
                let ring = ModelEntity(
                    mesh: .generatePlane(width: 1, depth: 1),
                    materials: [TrackingStage.unlit(texture: ringTexture)]
                )
                ring.position = Self.fixationPoint + SIMD3<Float>(0, 0.02, 0)
                ring.components.set(OpacityComponent(opacity: 0))
                ring.isEnabled = false
                root.addChild(ring)
                ripples.append(ring)
                rippleStarts.append(-100)
            }
        }

        // A few faint fireflies drifting near the far shore.
        let fireflyMesh = MeshResource.generateSphere(radius: 0.05)
        let fireflyMaterial = TrackingStage.unlit(color: UIColor(red: 1, green: 0.9, blue: 0.55, alpha: 1), opacity: 0.7)
        for index in 0..<14 {
            let angle: Float = Float.random(in: -1.1...1.1)
            let distance: Float = Float.random(in: 14...24)
            let base = SIMD3<Float>(sin(angle) * distance, Float.random(in: 0.4...2.2), -cos(angle) * distance)
            let fly = ModelEntity(mesh: fireflyMesh, materials: [fireflyMaterial])
            fly.position = base
            root.addChild(fly)
            fireflies.append((fly, base, Float(index) * 0.9))
        }
    }

    /// Called every frame while the rest scene is showing.
    func update(session: SessionController, now: Date) {
        let breath: Float = session.isActive && session.phase.isRest ? session.breath(at: now) : 0.35
        let haloScale: Float = 1 + 0.22 * breath
        moonHalo.scale = SIMD3<Float>(repeating: haloScale)
        moonHalo.components.set(OpacityComponent(opacity: 0.45 + 0.4 * breath))
        reflection.components.set(OpacityComponent(opacity: 0.35 + 0.3 * breath))

        let seconds: Float = Float(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))
        let shimmer: Float = 1 + 0.04 * sin(seconds * 1.3)
        reflection.scale = SIMD3<Float>(shimmer, 1, 1)

        // One ripple at the start of every breath in.
        let elapsed = session.elapsed(at: now)
        if session.phase.isRest, !ripples.isEmpty {
            let cycle = Int(elapsed / SessionController.breathCycle)
            if cycle != lastCycle {
                lastCycle = cycle
                rippleStarts[nextRipple] = elapsed
                nextRipple = (nextRipple + 1) % ripples.count
            }
        } else {
            lastCycle = -1
        }
        let rippleLife: TimeInterval = SessionController.breathCycle * 1.6
        for (index, ring) in ripples.enumerated() {
            let age = elapsed - rippleStarts[index]
            guard session.phase.isRest, age >= 0, age < rippleLife else {
                ring.isEnabled = false
                continue
            }
            let t: Float = Float(age / rippleLife)
            let eased: Float = 1 - (1 - t) * (1 - t)
            let size: Float = 0.8 + 9 * eased
            ring.isEnabled = true
            ring.scale = SIMD3<Float>(size, 1, size)
            ring.components.set(OpacityComponent(opacity: 0.4 * (1 - t)))
        }

        for fly in fireflies {
            let t: Float = seconds * 0.25 + fly.phase
            let drift = SIMD3<Float>(0.6 * sin(t), 0.25 * sin(t * 1.7), 0.6 * cos(t * 0.8))
            fly.entity.position = fly.base + drift
            let glow: Float = 0.35 + 0.35 * (0.5 + 0.5 * sin(t * 2.3))
            fly.entity.components.set(OpacityComponent(opacity: glow))
        }
    }

    // MARK: - Drawing

    private static func drawWater(_ ctx: CGContext, _ size: CGFloat) {
        let colors = [
            CGColor(red: 0.010, green: 0.022, blue: 0.045, alpha: 1),
            CGColor(red: 0.018, green: 0.050, blue: 0.085, alpha: 1),
            CGColor(red: 0.035, green: 0.105, blue: 0.150, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) else { return }
        let center = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2,
                               options: [.drawsAfterEndLocation])
    }

    /// Two layers of hills; the nearer one carries pine trees. Low enough to keep the moon clear.
    private static func drawRidge(_ ctx: CGContext, _ width: CGFloat, _ height: CGFloat) {
        func ridge(_ u: CGFloat, seed: CGFloat) -> CGFloat {
            let a: CGFloat = sin(u * 2 * .pi * 3 + seed)
            let b: CGFloat = sin(u * 2 * .pi * 7 + seed * 2.1)
            let c: CGFloat = sin(u * 2 * .pi * 13 + seed * 0.7)
            return 0.5 + 0.28 * a + 0.14 * b + 0.06 * c
        }
        let layers: [(seed: CGFloat, base: CGFloat, amplitude: CGFloat, color: CGColor)] = [
            (1.3, 0.16, 0.24, CGColor(red: 0.040, green: 0.065, blue: 0.110, alpha: 1)),
            (4.1, 0.06, 0.16, CGColor(red: 0.012, green: 0.022, blue: 0.040, alpha: 1)),
        ]
        let steps = 512
        for layer in layers {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            for i in 0...steps {
                let u: CGFloat = CGFloat(i) / CGFloat(steps)
                let h: CGFloat = (layer.base + layer.amplitude * ridge(u, seed: layer.seed)) * height
                path.addLine(to: CGPoint(x: u * width, y: h))
            }
            path.addLine(to: CGPoint(x: width, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(layer.color)
            ctx.fillPath()
        }
        // Pine trees on the near hills.
        let near = layers[1]
        ctx.setFillColor(near.color)
        var x: CGFloat = 0
        while x < width {
            let u: CGFloat = x / width
            let ground: CGFloat = (near.base + near.amplitude * ridge(u, seed: near.seed)) * height
            let treeHeight: CGFloat = CGFloat.random(in: 0.05...0.13) * height
            let treeWidth: CGFloat = treeHeight * 0.42
            for tier in 0..<3 {
                let tierBase: CGFloat = ground - 2 + treeHeight * CGFloat(tier) * 0.28
                let tierWidth: CGFloat = treeWidth * (1 - CGFloat(tier) * 0.25)
                let tierTop: CGFloat = tierBase + treeHeight * (0.5 - CGFloat(tier) * 0.05)
                ctx.move(to: CGPoint(x: x - tierWidth / 2, y: tierBase))
                ctx.addLine(to: CGPoint(x: x + tierWidth / 2, y: tierBase))
                ctx.addLine(to: CGPoint(x: x, y: tierTop))
                ctx.closePath()
            }
            ctx.fillPath()
            x += CGFloat.random(in: 6...26)
        }
    }

    private static func drawMoonGlow(_ ctx: CGContext, _ size: CGFloat) {
        let colors = [
            CGColor(red: 0.95, green: 0.95, blue: 0.85, alpha: 0.45),
            CGColor(red: 0.70, green: 0.80, blue: 0.95, alpha: 0.12),
            CGColor(red: 0.50, green: 0.70, blue: 0.95, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) else { return }
        let center = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
    }

    /// Broken horizontal glints, brightest along the middle and fading at the sides and ends.
    private static func drawReflection(_ ctx: CGContext, _ width: CGFloat, _ height: CGFloat) {
        var y: CGFloat = 0
        while y < height {
            let along: CGFloat = y / height
            let endFade: CGFloat = sin(along * .pi)
            let glintWidth: CGFloat = width * CGFloat.random(in: 0.25...0.9) * (0.5 + 0.5 * endFade)
            let alpha: CGFloat = CGFloat.random(in: 0.15...0.55) * endFade
            ctx.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.85, alpha: alpha))
            let rect = CGRect(x: (width - glintWidth) / 2 + CGFloat.random(in: -6...6), y: y,
                              width: glintWidth, height: CGFloat.random(in: 2...5))
            ctx.fillEllipse(in: rect)
            y += CGFloat.random(in: 5...12)
        }
    }

    private static func drawRing(_ ctx: CGContext, _ size: CGFloat) {
        let center = CGPoint(x: size / 2, y: size / 2)
        for i in 0..<6 {
            let spread: CGFloat = CGFloat(i)
            let alpha: CGFloat = 0.5 - spread * 0.08
            ctx.setStrokeColor(CGColor(red: 0.75, green: 0.85, blue: 0.95, alpha: alpha))
            ctx.setLineWidth(3)
            let radius: CGFloat = size * 0.46 - spread * 3
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// A band around the participant with no top or bottom cap, so the sky stays open.
    private static func openCylinder(radius: Float, height: Float, segments: Int) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for i in 0...segments {
            let u: Float = Float(i) / Float(segments)
            let angle: Float = u * 2 * Float.pi
            let x: Float = sin(angle) * radius
            let z: Float = -cos(angle) * radius
            positions.append(SIMD3<Float>(x, 0, z))
            positions.append(SIMD3<Float>(x, height, z))
            uvs.append(SIMD2<Float>(u, 0))
            uvs.append(SIMD2<Float>(u, 1))
        }
        for i in 0..<segments {
            let a = UInt32(i * 2)
            indices.append(contentsOf: [a, a + 2, a + 1, a + 1, a + 2, a + 3])
        }
        var descriptor = MeshDescriptor(name: "ridge")
        descriptor.positions = MeshBuffer(positions)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}

/// Shown in the lake scene before the baseline: what to do, and a button to begin.
struct BaselineInstructionsCard: View {
    let session: SessionController
    /// In the control window (when the immersive view isn't available) there's no glass card or fixed width.
    var inWindow = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Before we begin")
                .font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Label("Sit comfortably with your back supported.", systemImage: "chair")
                Label("Rest your hands on your lap and keep still.", systemImage: "hand.raised")
                Label(inWindow ? "Look at the circle in the middle." : "Look at the moon's reflection on the water.",
                      systemImage: "moon.stars")
                Label(inWindow ? "Breathe gently as the circle grows and shrinks." : "Breathe gently as the moonlight glows and fades.",
                      systemImage: "wind")
            }
            .font(.title3)
            Text("This lasts 1 minute. The game starts automatically afterwards.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button {
                session.startBaseline()
            } label: {
                Label("Start baseline", systemImage: "play.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .buttonBorderShape(.capsule)
        }
        .padding(inWindow ? 0 : 36)
        .frame(width: inWindow ? nil : 720)
        .glassBackgroundEffect(displayMode: inWindow ? .never : .always)
    }
}

/// Gentle breathing words for the first few breaths of each rest, then only a faint progress line.
struct RestHUD: View {
    let session: SessionController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let elapsed = session.elapsed(at: context.date)
            let showWords = elapsed < SessionController.breathCycle * 3
            VStack(spacing: 16) {
                Text(session.phase == .recovery ? "Recovery — relax and breathe" : "Baseline — relax and breathe")
                    .font(.title2)
                    .opacity(elapsed < 6 ? 0.85 : 0)
                Text(session.isInhaling(at: context.date) ? "Breathe in…" : "Breathe out…")
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .opacity(showWords ? 0.8 : 0)
                ProgressView(value: session.progress(at: context.date))
                    .tint(.teal)
                    .frame(width: 320)
                    .opacity(0.35)
            }
            .foregroundStyle(.white)
            .animation(.easeInOut(duration: 1.2), value: showWords)
            .animation(.easeInOut(duration: 0.8), value: session.isInhaling(at: context.date))
        }
    }
}
