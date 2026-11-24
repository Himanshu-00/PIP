import SwiftUI
import AppKit

/// Pip, drawn to the design spec, watching the pointer: looks at it, likes
/// being hovered, hops when clicked, gets dizzy, dozes off. Paused with
/// Reduce Motion.
struct PipArt: View {

    enum Expression: Equatable {
        /// Dot mouth, looking forward (or at the cursor).
        case idle
        /// Eyes glancing side to side, small dot mouth, breathing.
        case thinking
        /// A small smile.
        case replying
        /// Ears up: looking at you, a little "o" mouth, bobbing to your voice.
        case listening
        /// Speaking: the mouth opens and closes.
        case talking
    }

    let expression: Expression
    var width: CGFloat = 144
    /// How loud you are while he listens, 0…1.
    var level: Double = 0
    /// Where Pip's middle is on screen, in AppKit coordinates (origin at the
    /// bottom left). Nil turns cursor tracking off.
    var screenCenter: CGPoint?
    /// Hover and click. Off when he's shrunk into the corner, so his
    /// full-size hit area doesn't sit over the text.
    var interactive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A plain object rather than SwiftUI state: it's updated every frame
    /// while drawing, and doing that to `@State` would invalidate the view
    /// from inside its own body.
    @State private var tracker = PipTracker()

    /// The orb sprites are square; the drawn Pip's viewBox is 200 × 198.
    static func height(forWidth width: CGFloat) -> CGFloat {
        OrbSprites.available ? width : width * 198 / 200
    }

    @ViewBuilder
    var body: some View {
        if OrbSprites.available { orbBody } else { drawnBody }
    }

    // MARK: - The orb

    /// The orb's body from the artwork; the eyes drawn live on top. The body
    /// only moves by transforms.
    private var orbBody: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let pose = tracker.pose(at: context.date,
                                    mouse: NSEvent.mouseLocation,
                                    center: screenCenter,
                                    animated: !reduceMotion)
            let time = context.date.timeIntervalSinceReferenceDate
            // He perks up for a moment when an answer is ready.
            let sincePerk = context.date.timeIntervalSince(tracker.perkedAt)
            let perk: CGFloat = sincePerk < 1.2 && !reduceMotion ? CGFloat(1 - sincePerk / 1.2) : 0
            let base: OrbSprites.Base = expression == .talking ? .speaking
                : (pose.booping || perk > 0) ? .excited : .plain
            let unit = width / 200          // pose values are in 200-wide art units
            let thinking = expression == .thinking && !reduceMotion
            let breath = thinking ? 1 + 0.035 * (1 - cos(2 * .pi * time / 3.2)) / 2 : 1
            // Listening looks just like idle; the search bar shows he's listening.
            let grow = CGFloat(breath) * (1 + 0.04 * pose.petting)
            let perkHop = -8 * perk * CGFloat(sin(.pi * min(1, Double(1 - perk) * 2.5)))

            ZStack {
                // The still glass orb, and over it the aurora — washing in
                // like a wave while the model thinks and sinking away after
                // (owner, 2026-11-21). Its frames stop once it's hidden.
                ForEach(OrbSprites.Base.allCases, id: \.self) { candidate in
                    if let image = OrbSprites.image(candidate) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .opacity(candidate == base ? 1 : 0)
                    }
                }
                if AuroraOrb.available {
                    AuroraOrb(visible: expression == .thinking)
                }
                Canvas { canvas, size in
                    drawOrbEyes(in: canvas, size: size, pose: pose, time: time, perk: perk)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: base)
            .frame(width: width, height: width)
            .brightness(Double(pose.petting) * 0.05)
            .scaleEffect(x: grow / pose.squash, y: grow * pose.squash, anchor: UnitPoint(x: 0.5, y: 0.8))
            .rotationEffect(.degrees(pose.lean * 0.6), anchor: UnitPoint(x: 0.5, y: 0.8))
            .offset(x: pose.faceShift.x * unit * 0.5,
                    y: (thinking ? 0 : pose.hop) + perkHop)
        }
        .frame(width: width, height: width)
        .onChange(of: expression) { old, new in
            if old == .thinking, new == .replying || new == .talking { tracker.perkedAt = Date() }
        }
        .overlay {
            if interactive {
                ClickableArea(onClick: { tracker.boop() }, onHover: { tracker.hovering = $0 })
            }
        }
        .onChange(of: interactive) { _, on in if !on { tracker.hovering = false } }
        .accessibilityLabel("Pip")
    }

    /// The eyes in the artwork's 1024-wide space, per pose.
    private func drawOrbEyes(in context: GraphicsContext, size: CGSize, pose: PipPose,
                             time: TimeInterval, perk: CGFloat) {
        var canvas = context
        canvas.scaleBy(x: size.width / 1024, y: size.height / 1024)
        let ink = Color(red: 0.87, green: 0.91, blue: 1)
        let halo = Color(red: 0.42, green: 0.55, blue: 1)

        // Draws a shape with its glow: two wide, faint strokes, then the eye.
        func glowing(_ path: Path) {
            canvas.stroke(path, with: .color(halo.opacity(0.2)), style: StrokeStyle(lineWidth: 34, lineJoin: .round))
            canvas.stroke(path, with: .color(halo.opacity(0.45)), style: StrokeStyle(lineWidth: 14, lineJoin: .round))
            canvas.fill(path, with: .color(ink))
        }
        func glowingLine(_ path: Path, _ width: CGFloat) {
            canvas.stroke(path, with: .color(halo.opacity(0.16)), style: StrokeStyle(lineWidth: width + 30, lineCap: .round))
            canvas.stroke(path, with: .color(halo.opacity(0.32)), style: StrokeStyle(lineWidth: width + 12, lineCap: .round))
            canvas.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        // Where he looks: the cursor, except while thinking.
        let look = CGPoint(x: pose.look.x * 5, y: pose.look.y * 5)
        // Above the aurora's wave (`AuroraOrb`, about 500–640 in this 1024
        // space): at 522 it ran through his eyes and they lost contrast.
        let left = CGPoint(x: 397 + look.x, y: 440 + look.y)
        let right = CGPoint(x: 627 + look.x, y: 440 + look.y)

        // Dizzy: spirals.
        if pose.dizzy > 0 {
            for (index, eye) in [left, right].enumerated() {
                var spiral = Path()
                let turn = pose.dizzySpin * (index == 0 ? 1 : -1)
                for step in 0 ..< 32 {
                    let t = Double(step) / 31
                    let angle = turn + t * 2.6 * .pi
                    let radius = CGFloat(4 + 40 * t)
                    let point = CGPoint(x: eye.x + radius * CGFloat(cos(angle)), y: eye.y + radius * CGFloat(sin(angle)))
                    if step == 0 { spiral.move(to: point) } else { spiral.addLine(to: point) }
                }
                glowingLine(spiral, 12)
            }
            return
        }

        // One pair of eyes for every mood: big soft squares; moods move them.
        func squircle(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Path {
            let height = max(h, 8)
            return Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - height / 2, width: w, height: height),
                        cornerRadius: min(w, height) * 0.44, style: .continuous)   // a bit rounder (0.34 before)
        }
        let tall: CGFloat = 100 * pose.blink * (1 - 0.6 * pose.sleepy)
        var shift = CGPoint.zero
        var stretch: CGFloat = 1
        switch expression {
        case .thinking:
            let glance = reduceMotion ? 0.5 : CGFloat((1 - cos(2 * .pi * time / 2.6)) / 2)
            shift = CGPoint(x: -12 + 40 * glance, y: -8)
        case .talking:
            let bounce = reduceMotion ? 0 : CGFloat(abs(sin(time * 9) * 0.7 + sin(time * 5.3) * 0.3))
            shift = CGPoint(x: 0, y: -8 * bounce)
        case .listening:
            stretch = 1 + 0.14 * CGFloat(level)
        case .idle, .replying:
            if pose.startled > 0 { stretch = 1.1 }
        }
        glowing(squircle(CGPoint(x: left.x + shift.x, y: left.y + shift.y), 90, tall * stretch))
        glowing(squircle(CGPoint(x: right.x + shift.x, y: right.y + shift.y), 90, tall * stretch))
    }

    // MARK: - The drawn Pip (fallback if the sprites are missing)

    @ViewBuilder
    private var drawnBody: some View {
        let height = Self.height(forWidth: width)
        ZStack(alignment: .bottom) {
            // The contact shadow stays put while Pip moves above it.
            Ellipse()
                .fill(Self.rgb(0x1D1D20))
                .frame(width: width * 0.52, height: 6)
                .offset(y: 2)

            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                let pose = tracker.pose(at: context.date,
                                        mouse: NSEvent.mouseLocation,
                                        center: screenCenter,
                                        animated: !reduceMotion)
                let time = context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    draw(in: &canvas, size: size, pose: pose, time: time)
                }
                .frame(width: width, height: height)
                // Thinking breathes instead of bobbing (drawn in the canvas).
                .offset(y: expression == .thinking ? 0 : pose.hop)
            }
        }
        .frame(width: width, height: height)
        // Clicks and hover land on a real NSView, because SwiftUI gestures
        // don't fire inside the island's non-activating panel.
        .overlay(ClickableArea(onClick: { tracker.boop() },
                               onHover: { tracker.hovering = $0 }))
        .accessibilityLabel("Pip")
    }

    // MARK: - Drawing

    private func draw(in canvas: inout GraphicsContext, size: CGSize, pose: PipPose, time: TimeInterval = 0) {
        let scale = size.width / 200
        canvas.scaleBy(x: scale, y: scale)
        canvas.translateBy(x: 0, y: 8)          // the viewBox starts at y = −8

        // Thinking (thinking spec section 4): he breathes — scale 1 → 1.035
        // → 1 over 3.2 s, anchored at 50% across and 90% down — in place of
        // the bob. No rocking, no thought bubbles.
        let thinking = expression == .thinking && !reduceMotion
        let listening = expression == .listening && !reduceMotion
        let breath = thinking ? 1 + 0.035 * (1 - cos(2 * .pi * time / 3.2)) / 2 : 1
        if thinking {
            let anchorY = 198 * 0.9 - 8     // 90% down the 198-tall viewBox
            canvas.translateBy(x: 100, y: anchorY)
            canvas.scaleBy(x: breath, y: breath)
            canvas.translateBy(x: -100, y: -anchorY)
        }
        // Listening: the sprout perks and quivers with your voice.
        let wiggle = listening ? sin(time * 14) * 10 * level : 0
        // …and he bobs, just a little, as you talk.
        let bob = listening ? 1 + 0.05 * level * (0.5 + 0.5 * sin(time * 9)) : 1

        // Lean and squash around the bottom of the body, so he tilts and
        // squishes from where he sits rather than from his middle.
        canvas.translateBy(x: 100, y: 174)
        canvas.rotate(by: .degrees(pose.lean))
        canvas.scaleBy(x: 1 / (pose.squash * bob), y: pose.squash * bob)
        canvas.translateBy(x: -100, y: -174)

        drawSprout(in: canvas, sway: pose.sway + wiggle)

        let body = Path(roundedRect: CGRect(x: 22, y: 36, width: 156, height: 138), cornerRadius: 66)
        canvas.fill(body, with: .color(Self.rgb(0xF6F1E6)))
        var inside = canvas
        inside.clip(to: body)
        inside.fill(Self.ellipse(100, 196, 120, 46), with: .color(Self.rgb(0xE3DAC6)))
        inside.fill(Self.ellipse(72, 62, 30, 13, rotation: -20), with: .color(.white.opacity(0.6)))

        // The face moves a little towards whatever he's looking at, which
        // reads as his head turning without the body having to.
        var face = canvas
        face.translateBy(x: pose.faceShift.x, y: pose.faceShift.y)
        drawEyes(in: face, pose: pose)

        let blush = Self.rgb(0xF3A6A6).opacity(min(1, 0.85 + 0.15 * pose.petting))
        let cheekGrow = 1 + 0.25 * pose.petting
        face.fill(Self.ellipse(55, 125, 13 * cheekGrow, 7 * cheekGrow), with: .color(blush))
        face.fill(Self.ellipse(145, 125, 13 * cheekGrow, 7 * cheekGrow), with: .color(blush))

        drawMouth(in: face, pose: pose, time: time)
    }

    private func drawSprout(in canvas: GraphicsContext, sway: Double) {
        var sprout = canvas
        sprout.translateBy(x: 97, y: 44)
        sprout.rotate(by: .degrees(sway))
        sprout.translateBy(x: -97, y: -44)
        var stem = Path()
        stem.move(to: CGPoint(x: 100, y: 44))
        stem.addCurve(to: CGPoint(x: 96, y: 14),
                      control1: CGPoint(x: 100, y: 32),
                      control2: CGPoint(x: 99, y: 23))
        sprout.stroke(stem, with: .color(Self.rgb(0x6FB354)),
                      style: StrokeStyle(lineWidth: 5, lineCap: .round))
        sprout.fill(Self.ellipse(80, 12, 19, 10, rotation: -18), with: .color(Self.rgb(0x8FD16F)))
        sprout.fill(Self.ellipse(113, 10, 17, 9, rotation: 20), with: .color(Self.rgb(0xA9E08A)))
    }

    private func drawEyes(in canvas: GraphicsContext, pose: PipPose) {
        let ink = Self.rgb(0x1D1B1A)

        // Thinking: his eyes glance side to side, (−5, +1) ↔ (+4, −1) over
        // 2.6 s, ease-in-out — whatever the cursor is doing; he's busy.
        let thinking = expression == .thinking
        let glance = reduceMotion ? 0.5 : (1 - cos(2 * .pi * Date.timeIntervalSinceReferenceDate / 2.6)) / 2
        let look = thinking ? CGPoint(x: -5 + 9 * glance, y: 1 - 2 * glance)
            : expression == .listening ? CGPoint(x: 0, y: -2)   // all attention, on you
            : pose.look
        let left = CGPoint(x: 78 + look.x, y: 106 + look.y)
        let right = CGPoint(x: 122 + look.x, y: 106 + look.y)

        // Dizzy: spinning spirals instead of eyes.
        if pose.dizzy > 0, !thinking {
            for (index, eye) in [left, right].enumerated() {
                var spiral = Path()
                let turn = pose.dizzySpin * (index == 0 ? 1 : -1)
                for step in 0 ..< 28 {
                    let t = Double(step) / 27
                    let angle = turn + t * 2.6 * .pi
                    let radius = CGFloat(1 + 7 * t)
                    let point = CGPoint(x: eye.x + radius * CGFloat(cos(angle)),
                                        y: eye.y + radius * CGFloat(sin(angle)))
                    if step == 0 { spiral.move(to: point) } else { spiral.addLine(to: point) }
                }
                canvas.stroke(spiral, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            return
        }

        // Petted, or being booped: happy closed eyes, like ^ ^.
        if (pose.petting > 0.6 || pose.booping) && !thinking {
            for eye in [left, right] {
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - 7, y: eye.y + 2))
                arc.addQuadCurve(to: CGPoint(x: eye.x + 7, y: eye.y + 2),
                                 control: CGPoint(x: eye.x, y: eye.y - 8))
                canvas.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
            return
        }

        // Open eyes, blinking — and drooping when he's dozing off.
        let lid = thinking ? 1 : pose.blink * (1 - 0.82 * pose.sleepy)
        var eyes = canvas
        eyes.translateBy(x: 100, y: left.y)
        eyes.scaleBy(x: 1, y: max(lid, 0.08))
        eyes.translateBy(x: -100, y: -left.y)
        for eye in [left, right] {
            eyes.fill(Self.ellipse(eye.x, eye.y, 6.5, 8.5), with: .color(ink))
            // The highlight drifts slightly less than the pupil, so the eye
            // looks round rather than like a sticker sliding about.
            eyes.fill(Self.ellipse(eye.x + 2.5 - look.x * 0.25, eye.y - 3.5 - look.y * 0.25, 2.2, 2.2),
                      with: .color(.white))
        }
    }

    private func drawMouth(in canvas: GraphicsContext, pose: PipPose, time: TimeInterval) {
        let ink = Self.rgb(0x1D1B1A)
        let smiling = expression == .replying || pose.petting > 0.3 || pose.booping

        if expression == .talking {
            // Opens and closes in an uneven rhythm, like speech.
            let open = reduceMotion ? 0.5 : abs(sin(time * 11) * 0.7 + sin(time * 7.3) * 0.3)
            canvas.fill(Self.ellipse(100, 124, 6, 2 + 5 * open), with: .color(ink))
            canvas.fill(Self.ellipse(100, 126 + 2 * open, 3.5, 1.5 * open), with: .color(Self.rgb(0xE07A7A)))
            return
        }
        if expression == .listening {
            canvas.fill(Self.ellipse(100, 125, 4, 4.5), with: .color(ink))
            return
        }
        if expression == .thinking {
            canvas.fill(Self.ellipse(100, 124, 3.5, 3), with: .color(ink))
        } else if pose.dizzy > 0 {
            // A wobbly line.
            var wobble = Path()
            wobble.move(to: CGPoint(x: 92, y: 124))
            wobble.addCurve(to: CGPoint(x: 108, y: 124),
                            control1: CGPoint(x: 96, y: 119), control2: CGPoint(x: 104, y: 129))
            canvas.stroke(wobble, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        } else if pose.startled > 0 {
            canvas.fill(Self.ellipse(100, 125, 4.5, 5.5 * (0.6 + 0.4 * pose.startled)), with: .color(ink))
        } else if smiling {
            // Wider and deeper the more he's enjoying it.
            let width = 6 + 3 * pose.petting
            var smile = Path()
            smile.move(to: CGPoint(x: 100 - width, y: 122))
            smile.addQuadCurve(to: CGPoint(x: 100 + width, y: 122),
                               control: CGPoint(x: 100, y: 129 + 3 * pose.petting))
            canvas.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        } else if pose.sleepy > 0.5 {
            canvas.fill(Self.ellipse(100, 125, 3, 2), with: .color(ink))
        } else {
            canvas.fill(Self.ellipse(100, 124, 4, 3.5), with: .color(ink))
        }
    }

    // MARK: - Helpers

    /// An SVG `<ellipse cx cy rx ry transform="rotate(r cx cy)">`.
    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                        rotation degrees: CGFloat = 0) -> Path {
        let path = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        guard degrees != 0 else { return path }
        let turn = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -cx, y: -cy)
        return path.applying(turn)
    }

    /// `#RRGGBB` as a colour.
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Pose

/// Everything about how Pip looks in one frame.
struct PipPose {
    /// Where the pupils sit, in drawing units, relative to looking straight ahead.
    var look: CGPoint = .zero
    var faceShift: CGPoint = .zero
    var lean: Double = 0
    var hop: CGFloat = 0
    var squash: CGFloat = 1
    var sway: Double = 0
    var blink: CGFloat = 1
    /// 0…1: how much he's enjoying the cursor resting on him.
    var petting: CGFloat = 0
    var booping = false
    /// 0…1: how dizzy, and the angle the spirals have turned to.
    var dizzy: CGFloat = 0
    var dizzySpin: Double = 0
    /// 0…1: how close to asleep.
    var sleepy: CGFloat = 0
    /// 0…1: the jolt of being woken.
    var startled: CGFloat = 0
}

/// The pointer's movement as Pip's pose, eased frame by frame.
final class PipTracker {

    var hovering = false
    /// When an answer last arrived, so the orb can perk up.
    var perkedAt = Date.distantPast

    private var smoothedLook = CGPoint.zero
    private var smoothedLean = 0.0
    private var smoothedPetting: CGFloat = 0
    private var lastTime: Date?
    private var lastMouse: CGPoint?
    private var lastMoved = Date()
    /// How long the cursor has been moving very fast, for spotting a shake.
    private var shaking = 0.0
    private var dizzyUntil = Date.distantPast
    private var boopedAt = Date.distantPast
    private var startledAt = Date.distantPast

    /// Seconds without movement before he starts to doze.
    private let dozeAfter = 25.0

    func boop() { boopedAt = Date() }

    func pose(at now: Date, mouse: CGPoint, center: CGPoint?, animated: Bool) -> PipPose {
        let t = now.timeIntervalSinceReferenceDate
        let dt = min(max(now.timeIntervalSince(lastTime ?? now), 0), 0.1)
        lastTime = now
        var pose = PipPose()

        // The spec's idle motion.
        pose.sway = animated ? -4 + 9 * (1 - cos(2 * .pi * t / 4.4)) / 2 : 0
        let bob = animated ? CGFloat(-4 * (1 - cos(2 * .pi * t / 3.6)) / 2) : 0
        pose.blink = animated ? Self.blink(t) : 1

        // Movement: speed for shaking, time since the last move for dozing.
        if let lastMouse, dt > 0 {
            let distance = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
            if distance > 1.5 {
                // Moving again after a doze is a jolt awake.
                if now.timeIntervalSince(lastMoved) > dozeAfter { startledAt = now }
                lastMoved = now
            }
            let speed = Double(distance) / dt
            shaking = speed > 3_500 ? shaking + dt : max(0, shaking - dt * 2)
            if shaking > 0.35 {
                dizzyUntil = now.addingTimeInterval(1.8)
                shaking = 0
            }
        }
        lastMouse = mouse

        // Where to look: a direction, squashed so that far away doesn't mean
        // eyes out of their sockets. Screen y grows upwards; drawing y down.
        var targetLook = CGPoint.zero
        var targetLean = 0.0
        if let center {
            let dx = Double(mouse.x - center.x)
            let dy = Double(center.y - mouse.y)
            targetLook = CGPoint(x: 6 * dx / (abs(dx) + 160), y: 5 * dy / (abs(dy) + 140))
            targetLean = 5 * dx / (abs(dx) + 400)
        }
        let ease = CGFloat(1 - exp(-dt * 10))
        smoothedLook.x += (targetLook.x - smoothedLook.x) * ease
        smoothedLook.y += (targetLook.y - smoothedLook.y) * ease
        smoothedLean += (targetLean - smoothedLean) * (1 - exp(-dt * 4))
        smoothedPetting += ((hovering ? 1 : 0) - smoothedPetting) * CGFloat(1 - exp(-dt * 6))

        pose.look = smoothedLook
        pose.faceShift = CGPoint(x: smoothedLook.x * 0.45, y: smoothedLook.y * 0.35)
        pose.lean = smoothedLean
        pose.petting = smoothedPetting

        // Petting: a happy little wiggle.
        if animated, smoothedPetting > 0.3 {
            pose.lean += sin(t * 9) * 2.5 * Double(smoothedPetting)
        }

        // Boop: squash, then hop, over 0.5 s.
        let sinceBoop = now.timeIntervalSince(boopedAt)
        if sinceBoop < 0.5 {
            pose.booping = true
            let p = sinceBoop / 0.5
            if animated {
                pose.squash = CGFloat(1 - 0.12 * sin(.pi * min(p * 2.5, 1)))
                pose.hop = bob - CGFloat(10 * sin(.pi * p))
            }
        } else {
            pose.hop = bob
        }

        // Dizzy: spinning eyes and a bit of a sway.
        let dizzyLeft = dizzyUntil.timeIntervalSince(now)
        if dizzyLeft > 0 {
            pose.dizzy = CGFloat(min(1, dizzyLeft / 0.4))
            pose.dizzySpin = t * 8
            if animated { pose.lean += sin(t * 5) * 6 }
        }

        // Dozing: eyes droop over a few seconds, the bob slows to breathing.
        let idle = now.timeIntervalSince(lastMoved)
        if !hovering, idle > dozeAfter {
            pose.sleepy = CGFloat(min(1, (idle - dozeAfter) / 4))
        }

        // Startled awake: a quick jump and a little "o" mouth.
        let sinceStartle = now.timeIntervalSince(startledAt)
        if sinceStartle < 0.6 {
            pose.startled = CGFloat(1 - sinceStartle / 0.6)
            if animated { pose.hop -= 6 * pose.startled }
        }

        return pose
    }

    /// Eyes open for 91% of a 5.2 s cycle, closed to 12% at 95%, open again by 100%.
    private static func blink(_ t: Double) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 5.2) / 5.2
        func ease(_ x: Double) -> Double { (1 - cos(.pi * x)) / 2 }
        if phase < 0.91 { return 1 }
        if phase < 0.95 { return CGFloat(1 - 0.88 * ease((phase - 0.91) / 0.04)) }
        return CGFloat(0.12 + 0.88 * ease((phase - 0.95) / 0.05))
    }
}


/// The orb's body PNGs in `Pet/Orb/`, loaded once; missing → drawn Pip.
enum OrbSprites {

    enum Base: String, CaseIterable {
        case plain = "orb-base"
        case speaking = "orb-base-speaking"
        case excited = "orb-base-excited"
    }

    private static let images: [Base: NSImage] = {
        var found: [Base: NSImage] = [:]
        for base in Base.allCases {
            let url = Bundle.main.url(forResource: base.rawValue, withExtension: "png")
                ?? Bundle.main.url(forResource: base.rawValue, withExtension: "png", subdirectory: "Orb")
            if let url, let image = NSImage(contentsOf: url) { found[base] = image }
        }
        return found
    }()

    static var available: Bool { images[.plain] != nil }

    static func image(_ base: Base) -> NSImage? { images[base] ?? images[.plain] }
}

