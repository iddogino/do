import DoCore
import Observation
import SwiftUI

@MainActor
@Observable
final class CursorModel {
    enum Mode: Equatable {
        case pointer
        case thinking
        case dragging
        case scrolling(dx: Double, dy: Double)
    }

    enum Badge: Equatable {
        case none
        case thinking
        case text(icon: String, text: String)
        case typing(String)
        case keys([String])
        case waiting(seconds: Double)
    }

    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        let point: CGPoint
        let tint: Color
        let delay: Double
    }

    var visible = false
    var position: CGPoint = .zero
    var mode: Mode = .pointer
    var badge: Badge = .none
    var ripples: [Ripple] = []
    var pressed = false
    var dragStart: CGPoint?
}

/// The classic macOS arrow, tip at (0, 0), 24 pt tall.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 19.5))
        p.addLine(to: CGPoint(x: 4.8, y: 15.2))
        p.addLine(to: CGPoint(x: 8.1, y: 22.6))
        p.addLine(to: CGPoint(x: 11.6, y: 21.1))
        p.addLine(to: CGPoint(x: 8.4, y: 13.9))
        p.addLine(to: CGPoint(x: 14.6, y: 13.9))
        p.closeSubpath()
        return p
    }
}

struct CursorOverlayView: View {
    @Bindable var model: CursorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if let start = model.dragStart {
                Path { p in
                    p.move(to: start)
                    p.addLine(to: model.position)
                }
                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 6]))
                .opacity(0.85)
                Circle().fill(Theme.brand[0]).frame(width: 9, height: 9).position(start)
            }

            ForEach(model.ripples) { ripple in
                RippleView(tint: ripple.tint, delay: ripple.delay).position(ripple.point)
            }

            if model.visible {
                cursor
                    .position(x: model.position.x, y: model.position.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var cursor: some View {
        // A zero-size anchor at the tip; the glyph and badge hang off it.
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            glyph
            badge
                .offset(x: 20, y: 26)
                .fixedSize()
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
    }

    @ViewBuilder
    private var glyph: some View {
        switch model.mode {
        case .scrolling(let dx, let dy):
            ScrollIndicator(dx: dx, dy: dy)
                .offset(x: -17, y: -26)
                .transition(.scale.combined(with: .opacity))
        default:
            ZStack(alignment: .topLeading) {
                if model.mode == .thinking {
                    ThinkingHalo().offset(x: -14, y: -14)
                }
                ArrowShape()
                    .fill(Theme.brandGradient)
                    .overlay(ArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
                    .frame(width: 15, height: 23, alignment: .topLeading)
                    .shadow(color: Theme.brand[1].opacity(0.75), radius: 7)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .scaleEffect(model.pressed ? 0.82 : (model.mode == .dragging ? 0.9 : 1), anchor: .topLeading)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: model.pressed)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch model.badge {
        case .none:
            EmptyView()
        case .thinking:
            BadgeView { ShimmerText(text: "Thinking") }
        case .text(let icon, let text):
            BadgeView {
                Label(text, systemImage: icon).lineLimit(1).frame(maxWidth: 320, alignment: .leading)
            }
        case .typing(let text):
            BadgeView { TypewriterText(text: text) }
        case .keys(let keys):
            BadgeView {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(Self.keySymbol(key))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.18)))
                    }
                }
            }
        case .waiting(let seconds):
            BadgeView { Label("Waiting \(Int(seconds.rounded()))s", systemImage: "hourglass") }
        }
    }

    static func keySymbol(_ key: String) -> String {
        switch key.lowercased() {
        case "cmd", "command", "super", "meta", "win": "⌘"
        case "ctrl", "control": "⌃"
        case "alt", "option": "⌥"
        case "shift": "⇧"
        case "enter", "return": "↩"
        case "tab": "⇥"
        case "esc", "escape": "esc"
        case "backspace": "⌫"
        case "delete", "del": "⌦"
        case "space": "space"
        case "up", "arrowup": "↑"
        case "down", "arrowdown": "↓"
        case "left", "arrowleft": "←"
        case "right", "arrowright": "→"
        default: key.count == 1 ? key.uppercased() : key
        }
    }
}

struct BadgeView<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(.black.opacity(0.78))
                    .overlay(Capsule().strokeBorder(Theme.brandGradient.opacity(0.7), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topLeading)))
    }
}

struct RippleView: View {
    let tint: Color
    let delay: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 2.5)
            .frame(width: 44, height: 44)
            .scaleEffect(expanded ? 1.15 : 0.15)
            .opacity(expanded ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55).delay(delay)) { expanded = true }
            }
    }
}

struct ThinkingHalo: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Theme.brand[1].opacity(0.45), .clear], center: .center, startRadius: 2, endRadius: 22))
            .frame(width: 44, height: 44)
            .scaleEffect(pulse ? 1.15 : 0.75)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Mouse-wheel style indicator with chevrons flowing in the scroll direction.
struct ScrollIndicator: View {
    let dx: Double
    let dy: Double
    @State private var phase = false

    /// Model convention: negative dy scrolls down (content moves up).
    private var angle: Angle {
        if dy != 0 { return dy < 0 ? .degrees(0) : .degrees(180) }
        return dx < 0 ? .degrees(90) : .degrees(-90)
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.8))
                .overlay(Capsule().strokeBorder(Theme.brandGradient, lineWidth: 2))
                .frame(width: 34, height: 52)
                .shadow(color: Theme.brand[1].opacity(0.6), radius: 8)
            VStack(spacing: -3) {
                ForEach(0 ..< 3) { i in
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .opacity(phase ? (i == 2 ? 1 : 0.35) : (i == 0 ? 1 : 0.35))
                }
            }
            .offset(y: phase ? 4 : -4)
            .rotationEffect(angle)
            .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: false), value: phase)
        }
        .onAppear { phase = true }
    }
}

struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1
    var body: some View {
        Text(text + "…")
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 40)
                .offset(x: phase * 60)
                .blendMode(.sourceAtop)
            )
            .compositingGroup()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Reveals `text` progressively, roughly in step with the synthetic typing.
struct TypewriterText: View {
    let text: String
    @State private var shown = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
            Text(display).lineLimit(1).frame(maxWidth: 300, alignment: .leading)
            Rectangle().fill(.white).frame(width: 1.5, height: 12).opacity(0.8)
        }
        .task(id: text) {
            shown = 0
            for i in 1 ... max(1, text.count) {
                shown = i
                try? await Task.sleep(for: .milliseconds(text.count > 120 ? 4 : 14))
                if Task.isCancelled { return }
            }
        }
    }

    private var display: String {
        let visible = String(text.prefix(shown)).replacingOccurrences(of: "\n", with: "⏎ ")
        return visible.count > 48 ? "…" + visible.suffix(47) : visible
    }
}
