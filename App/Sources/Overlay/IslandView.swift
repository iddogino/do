import DoCore
import SwiftUI

/// The black shape that grows out of the notch / Dynamic Island: flush with the top bezel,
/// with small concave flares where it meets the screen edge (like the hardware notch) and
/// rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.height - t) / 1.2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Brand-gradient activity ring.
struct Spinner: View {
    var size: CGFloat = 15
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.82)
            .stroke(
                AngularGradient(colors: Theme.brand + [Theme.brand[0]], center: .center),
                style: StrokeStyle(lineWidth: size / 6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

/// Single-line text that scrolls horizontally when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium)
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            HStack(spacing: 40) {
                label
                if overflow { label }
            }
            .fixedSize()
            .offset(x: overflow ? offset : max(0, (geo.size.width - textWidth) / 2))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: overflow
                        ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                           .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .leading, endPoint: .trailing)
            )
            .onChange(of: text, initial: true) { restart(overflow: textWidth > geo.size.width + 1) }
            .onChange(of: textWidth) { restart(overflow: textWidth > geo.size.width + 1) }
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }

    private func restart(overflow: Bool) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard overflow else { return }
        let distance = textWidth + 40
        withAnimation(.linear(duration: Double(distance) / 38).delay(1.2).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

struct IslandView: View {
    @Bindable var model: IslandModel
    /// Space between the top of the panel and the island (menu bar height for floating style).
    let topInset: CGFloat
    let onFrameChange: (CGRect) -> Void

    private let earWidth: CGFloat = 86
    private let stripHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            island
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.approval)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.escapeArmed)
    }

    private var isVisible: Bool { model.phase != .hidden }
    private var showsDetail: Bool { model.expanded || model.approval != nil }

    @ViewBuilder
    private var island: some View {
        switch model.style {
        case .notch(let cutout), .dynamicIsland(let cutout):
            cutoutIsland(cutout: cutout, isDynamicIsland: model.style != .notch(cutout: cutout))
        case .floating:
            floatingIsland
        }
    }

    // MARK: Notch / Dynamic Island

    private func cutoutIsland(cutout: CGSize, isDynamicIsland: Bool) -> some View {
        let compactWidth = cutout.width + 2 * earWidth
        let width = showsDetail ? max(compactWidth, 500) : compactWidth
        return VStack(spacing: 0) {
            // Top band beside the camera: spinner on the left, stop on the right.
            HStack(spacing: 0) {
                leadingGlyph.frame(width: earWidth)
                Spacer(minLength: cutout.width)
                trailingButton.frame(width: earWidth)
            }
            .frame(height: cutout.height)

            if showsDetail {
                detail
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                statusLine
                    .frame(height: stripHeight)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 2)
            }
        }
        .frame(width: isVisible ? width : cutout.width)
        .frame(maxHeight: isVisible ? nil : cutout.height, alignment: .top)
        .background {
            if isDynamicIsland {
                RoundedRectangle(cornerRadius: showsDetail ? 30 : (cutout.height + stripHeight) / 2, style: .continuous)
                    .fill(.black)
            } else {
                NotchShape(topRadius: 9, bottomRadius: showsDetail ? 26 : 18).fill(.black)
            }
        }
        .clipShape(Rectangle())
        .opacity(isVisible ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if model.approval == nil { model.expanded.toggle() } }
        .shadow(color: .black.opacity(showsDetail ? 0.35 : 0), radius: 18, y: 8)
    }

    // MARK: Floating pill

    private var floatingIsland: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                leadingGlyph.frame(width: 18)
                statusLine
                trailingButton
            }
            .frame(height: 38)
            .padding(.horizontal, 12)
            if showsDetail {
                detail
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: showsDetail ? 500 : 400)
        .background(
            RoundedRectangle(cornerRadius: showsDetail ? 24 : 19, style: .continuous)
                .fill(.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: showsDetail ? 24 : 19, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .scaleEffect(isVisible ? 1 : 0.6, anchor: .top)
        .opacity(isVisible ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if model.approval == nil { model.expanded.toggle() } }
    }

    // MARK: Pieces

    @ViewBuilder
    private var leadingGlyph: some View {
        switch model.phase {
        case .finished(let outcome):
            Image(systemName: Self.symbol(for: outcome))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.tint(for: outcome))
                .transition(.scale.combined(with: .opacity))
        default:
            if model.approval != nil {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            } else {
                Spinner()
            }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if model.isRunning {
            Button(action: model.onStop) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help("Stop Do (or press Escape twice)")
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }

    private var statusLine: some View {
        MarqueeText(
            text: model.displayStatus,
            font: .system(size: 12.5, weight: .medium),
            color: model.escapeArmed ? Theme.warning : .white
        )
        .id(model.displayStatus)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        .animation(.easeOut(duration: 0.25), value: model.displayStatus)
    }

    @ViewBuilder
    private var detail: some View {
        if let request = model.approval {
            ApprovalCard(request: request, decide: model.onApprovalDecision)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.task)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if model.step > 0 {
                        Text("Step \(model.step)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(model.displayStatus)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(model.escapeArmed ? Theme.warning : .white.opacity(0.92))
                    .lineLimit(3)
                if !model.thinking.isEmpty, model.isRunning {
                    Text(model.thinking)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.history.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.history.dropLast().suffix(4).enumerated()), id: \.offset) { _, line in
                            Label {
                                Text(line).lineLimit(1)
                            } icon: {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                if model.isRunning {
                    HStack {
                        Text("Press Esc twice to stop")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Button("Stop", action: model.onStop)
                            .buttonStyle(IslandButtonStyle(tint: Theme.danger))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func symbol(for outcome: AgentOutcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    static func tint(for outcome: AgentOutcome) -> Color {
        switch outcome {
        case .completed: Theme.success
        case .stopped: .white.opacity(0.8)
        default: Theme.warning
        }
    }
}

struct ApprovalCard: View {
    let request: ApprovalRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Allow Do to run this command?", systemImage: "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(request.command)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(6)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            if !request.reasons.isEmpty {
                Text("This command " + request.reasons.formatted(.list(type: .and)) + ".")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning.opacity(0.9))
            }
            HStack {
                Spacer()
                Button("Don’t Run") { decide(false) }
                    .buttonStyle(IslandButtonStyle(tint: .white.opacity(0.18)))
                Button("Run") { decide(true) }
                    .buttonStyle(IslandButtonStyle(tint: Theme.brand[0]))
            }
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
