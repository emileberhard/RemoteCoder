import SwiftUI

/// Transient presentation only; the originating control owns the settings write.
@Observable @MainActor
final class ReasoningPickerPresentation {
    private(set) var session: Session?
    // Input ends immediately; its visual survives until the return animation ends.
    private(set) var presentedSession: Session?
    private var viewport: CGRect = .zero
    private let feedback: (HapticEvent, UUID) -> Void

    init(feedback: @escaping (HapticEvent, UUID) -> Void = { HapticService.shared.playInteraction($0, owner: $1) }) {
        self.feedback = feedback
    }

    func updateViewport(_ frame: CGRect) {
        guard viewport != frame else { return }
        dismissImmediately()
        viewport = frame
    }

    func present(
        owner: UUID, model: ModelOption, efforts: [ReasoningEffort], selection: ReasoningSelection,
        source: CGRect, held: Bool, isRightToLeft: Bool,
        commit: @escaping (ReasoningSelection) -> Void
    ) -> Session? {
        let choices = ReasoningSelection.choices(among: efforts)
        let width = min(400, viewport.width - 48)
        guard choices.count > 1, choices.contains(selection), !source.isEmpty,
              width > 2 * ReasoningPickerTrack.thumbInset else { return nil }
        let centerX = min(max(source.midX, viewport.minX + 24 + width / 2), viewport.maxX - 24 - width / 2)
        let halfHeight = ReasoningPickerTrack.height / 2
        let centerY = min(max(source.midY - 12, viewport.minY + halfHeight + 68),
                          viewport.maxY - halfHeight - 12)
        let frame = CGRect(x: centerX - width / 2, y: centerY - ReasoningPickerTrack.height / 2,
                           width: width, height: ReasoningPickerTrack.height)
        let session = Session(owner: owner, title: model.displayName, choices: choices,
                              initial: selection, frame: frame, sourceFrame: source, held: held,
                              isRightToLeft: isRightToLeft, feedback: { [feedback] event in feedback(event, owner) }, commit: commit)
        self.session?.invalidate()
        self.session = session
        presentedSession = session
        feedback(.lift, owner)
        return session
    }

    func dismiss(owner: UUID) {
        guard session?.owner == owner else { return }
        dismiss()
    }

    func dismiss() {
        session?.invalidate()
        session = nil
    }

    func completeDismissal(of session: Session) {
        guard self.session == nil, presentedSession === session else { return }
        presentedSession = nil
    }

    func dismissImmediately() {
        dismiss()
        presentedSession = nil
    }

    func finish(_ session: Session, at location: CGPoint) {
        guard self.session === session else { return }
        session.updateFinalPosition(at: location)
        finish(session)
    }

    func finish(_ session: Session) {
        guard self.session === session else { return }
        let wasCancelled = session.isCancelled
        let selection = session.selection
        let shouldRelease = session.held || session.hasDragged
        session.invalidate()
        self.session = nil
        guard !wasCancelled else { return }
        if shouldRelease { feedback(.sliderRelease, session.owner) }
        if selection != session.initial { session.commit(selection) }
    }

    @Observable @MainActor
    final class Session: Identifiable {
        let id = UUID()
        let owner: UUID
        let title: String
        let choices: [ReasoningSelection]
        let initial: ReasoningSelection
        let frame: CGRect
        let sourceFrame: CGRect
        let held: Bool
        let isRightToLeft: Bool
        let commit: (ReasoningSelection) -> Void
        private(set) var selection: ReasoningSelection
        private(set) var isCancelled = false
        private(set) var hasDragged = false
        private var isValid = true
        private let feedback: (HapticEvent) -> Void
        private var holdOrigin: CGPoint?

        init(owner: UUID, title: String, choices: [ReasoningSelection],
             initial: ReasoningSelection, frame: CGRect, sourceFrame: CGRect, held: Bool,
             isRightToLeft: Bool, feedback: @escaping (HapticEvent) -> Void, commit: @escaping (ReasoningSelection) -> Void) {
            self.owner = owner
            self.title = title
            self.choices = choices
            self.initial = initial
            self.selection = initial
            self.frame = frame
            self.sourceFrame = sourceFrame
            self.held = held
            self.isRightToLeft = isRightToLeft
            self.commit = commit
            self.feedback = feedback
        }

        func updateHold(at location: CGPoint) {
            applyHold(at: location, reportsDetent: true)
        }

        /// The release owns the final contact. Do not request a detent and release
        /// in the same callback and rely on SwiftUI/the hardware to merge them.
        func updateFinalPosition(at location: CGPoint) {
            if held { applyHold(at: location, reportsDetent: false) }
            else { update(at: location, reportsDetent: false) }
        }

        private func applyHold(at location: CGPoint, reportsDetent: Bool) {
            guard isValid else { return }
            guard let origin = holdOrigin else {
                holdOrigin = location
                return
            }
            hasDragged = hasDragged || abs(location.x - origin.x) >= 4 || abs(location.y - origin.y) >= 4
            if hasDragged { update(at: location, reportsDetent: reportsDetent) }
        }

        func beginDrag() {
            guard isValid, !hasDragged else { return }
            hasDragged = true
            if !held { feedback(.sliderGrab) }
        }

        func invalidate() { isValid = false }

        func update(at location: CGPoint) {
            update(at: location, reportsDetent: true)
        }

        private func update(at location: CGPoint, reportsDetent: Bool) {
            guard isValid else { return }
            isCancelled = abs(location.y - frame.midY) > 100
            guard !isCancelled else { return }
            let travel = frame.width - 2 * ReasoningPickerTrack.thumbInset
            let position = (location.x - frame.minX - ReasoningPickerTrack.thumbInset) / travel
            let fraction = min(max(isRightToLeft ? 1 - position : position, 0), 1)
            guard let current = choices.firstIndex(of: selection) else { return }
            let index = ReasoningDetents.index(at: fraction, count: choices.count, current: current)
            select(index: index, reportsDetent: reportsDetent)
        }

        func select(index: Int) {
            select(index: index, reportsDetent: true)
        }

        private func select(index: Int, reportsDetent: Bool) {
            guard isValid, choices.indices.contains(index), choices[index] != selection else { return }
            selection = choices[index]
            if reportsDetent {
                feedback(index == 0 ? .sliderMinimum : index == choices.count - 1 ? .sliderMaximum : .sliderStep)
            }
        }

        func resetPreview() {
            guard isValid else { return }
            selection = initial
            isCancelled = false
            hasDragged = false
            holdOrigin = nil
        }
    }
}

enum ReasoningDetents {
    /// Ten percent of a step on either side of a boundary prevents jitter from
    /// changing the value as well as the feedback. Large moves still skip directly.
    static func index(at fraction: CGFloat, count: Int, current: Int) -> Int {
        precondition(count > 1 && (0..<count).contains(current))
        let position = min(max(fraction, 0), 1) * CGFloat(count - 1)
        let bias: CGFloat = position > CGFloat(current) ? -0.1 : 0.1
        return min(max(Int((position + bias).rounded()), 0), count - 1)
    }
}

extension View {
    func reasoningPickerOverlay() -> some View {
        modifier(ReasoningPickerHost())
    }
}

private struct ReasoningPickerHost: ViewModifier {
    @State private var picker = ReasoningPickerPresentation()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(picker)
            .accessibilityHidden(picker.session != nil)
            // Source and destination are both SwiftUI global frames; convert
            // into this overlay once, including its safe-area/keyboard offset.
            .overlay {
                GeometryReader { geometry in
                    if let session = picker.presentedSession {
                        ReasoningPickerLayer(picker: picker, session: session,
                            overlayOrigin: geometry.frame(in: .global).origin)
                            .id(session.id)
                            .transition(.identity)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.updateViewport($0) }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { picker.dismissImmediately() } }
            .onDisappear { picker.dismissImmediately() }
    }
}

private struct ReasoningPickerLayer: View {
    let picker: ReasoningPickerPresentation
    let session: ReasoningPickerPresentation.Session
    let overlayOrigin: CGPoint
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { picker.dismiss() }
                .accessibilityHidden(true)
            ReasoningPickerBackdrop()
                .frame(width: session.frame.width + 160, height: 320)
                .position(x: session.frame.midX - overlayOrigin.x, y: session.frame.midY - overlayOrigin.y - 12)
                .opacity(isExpanded ? 1 : 0)
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isExpanded)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ReasoningPickerMorph(picker: picker, session: session, overlayOrigin: overlayOrigin,
                progress: isExpanded ? 1 : 0, reduceMotion: reduceMotion)
            Color.clear
                .frame(width: session.frame.width, height: 0)
                .overlay(alignment: .bottom) {
                    ReasoningPickerHeading(picker: picker, session: session)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .position(x: session.frame.midX - overlayOrigin.x, y: session.frame.minY - overlayOrigin.y - 12)
                .opacity(isExpanded ? 1 : 0)
                .animation(.easeOut(duration: 0.12).delay(isExpanded && !reduceMotion ? 0.06 : 0), value: isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Preserve the originating UIKit touch for hold/slide/release.
        .allowsHitTesting(picker.session === session && !session.held)
        .accessibilityHidden(picker.session !== session || session.held)
        .onChange(of: picker.session?.id, initial: true) {
            if picker.session === session {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.04)) {
                    isExpanded = true
                }
            } else {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22), completionCriteria: .removed) {
                    isExpanded = false
                } completion: {
                    picker.completeDismissal(of: session)
                }
            }
        }
    }
}

/// One interpolated rectangle: a gauge-sized circle widens into a capsule.
/// The track lays out inside that rectangle, so its thumb stays circular and
/// the labels never become miniature, travelling copies of themselves.
private struct ReasoningPickerMorph: View, Animatable {
    let picker: ReasoningPickerPresentation
    let session: ReasoningPickerPresentation.Session
    let overlayOrigin: CGPoint
    var progress: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let amount = reduceMotion ? 1 : min(max(progress, 0), 1)
        let source = session.sourceFrame
        let target = session.frame
        let size = CGSize(width: source.width + (target.width - source.width) * amount,
                          height: source.height + (target.height - source.height) * amount)
        let trackVisibility = reduceMotion ? 1 : min(1, amount / 0.45)
        let efforts = session.choices.compactMap { choice -> ReasoningEffort? in
            if case let .effort(effort) = choice { return effort }
            return nil
        }
        ZStack {
            ReasoningPickerPanel(picker: picker, session: session, size: size,
                trackVisibility: trackVisibility)
            if !reduceMotion {
                ReasoningEffortIndicator(
                    position: ReasoningGaugePosition(efforts: efforts, selection: session.initial),
                    height: source.height
                )
                    .opacity(1 - trackVisibility)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .position(x: source.midX + (target.midX - source.midX) * amount - overlayOrigin.x,
                  y: source.midY + (target.midY - source.midY) * amount - overlayOrigin.y)
        .opacity(reduceMotion ? progress : 1)
        // Interpolation is already supplied by animatableData. Only the thumb's
        // own selection animation should run inside these intermediate frames.
        .transaction { $0.animation = nil }
    }
}

private struct ReasoningPickerBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(reduceTransparency
                  ? AnyShapeStyle(colorScheme == .dark ? Color.black : Color.white)
                  : AnyShapeStyle(.regularMaterial))
            .mask {
                Ellipse()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 36)
                    .blur(radius: 28)
            }
    }
}

private struct ReasoningPickerPanel: View {
    let picker: ReasoningPickerPresentation
    let session: ReasoningPickerPresentation.Session
    let size: CGSize
    let trackVisibility: CGFloat
    @AccessibilityFocusState private var sliderFocused: Bool
    @GestureState private var isDragging = false

    var body: some View {
        if let index = session.choices.firstIndex(of: session.selection) {
            ReasoningPickerTrack(count: session.choices.count, selectedIndex: index, size: size)
                .opacity(trackVisibility)
                .background { Capsule().fill(.regularMaterial).opacity(trackVisibility) }
                .overlay { Capsule().strokeBorder(.primary.opacity(0.08 * Double(trackVisibility)), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08 * Double(trackVisibility)), radius: 6, y: 2)
                .contentShape(.capsule)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { session.beginDrag(); session.update(at: $0.location) }
                    .onEnded {
                        picker.finish(session, at: $0.location)
                    })
                .accessibilityRepresentation {
                    Slider(value: Binding(get: { Double(index) }, set: { value in
                        guard picker.session === session else { return }
                        session.select(index: Int(value.rounded()))
                        picker.finish(session)
                    }), in: 0...Double(session.choices.count - 1), step: 1) {
                        Text("Reasoning effort")
                    }
                    .accessibilityValue(session.selection.label)
                    .accessibilityIdentifier("conversation-reasoning-slider")
                    .accessibilityFocused($sliderFocused)
                }
                .opacity(session.isCancelled ? 0.5 : 1)
                .accessibilityAction(.escape) { picker.dismiss() }
                .onAppear { sliderFocused = !session.held }
                .onChange(of: isDragging) { _, dragging in
                    if !dragging, picker.session === session { session.resetPreview() }
                }
        }
    }
}

private struct ReasoningPickerHeading: View {
    let picker: ReasoningPickerPresentation
    let session: ReasoningPickerPresentation.Session

    var body: some View {
        VStack(spacing: 2) {
            Text(session.title)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(session.isCancelled ? "Release to cancel" : session.selection.label)
                .scaledFont(.title2.weight(.semibold))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, minHeight: 44)
        .overlay(alignment: .trailing) {
            Button("Close reasoning slider", systemImage: "xmark") { picker.dismiss() }
                .labelStyle(.iconOnly)
                .scaledFont(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
                .accessibilityIdentifier("close-reasoning-slider")
        }
    }
}

private struct ReasoningPickerTrack: View {
    nonisolated static let height: CGFloat = 96
    nonisolated static let thumbSize: CGFloat = height * 0.625
    nonisolated static let thumbInset: CGFloat = height / 2

    let count: Int
    let selectedIndex: Int
    let size: CGSize
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scale = size.height / Self.height
        let thumbSize = Self.thumbSize * scale
        let padding = (size.height - thumbSize) / 2
        let inset = Self.thumbInset * scale
        let travel = max(0, size.width - 2 * inset)
        let fraction = CGFloat(selectedIndex) / CGFloat(count - 1)
        let rtl = layoutDirection == .rightToLeft
        let thumbX = inset + travel * (rtl ? 1 - fraction : fraction)
        let fillWidth = thumbSize + travel * fraction

        ZStack {
            Capsule()
                .fill(themeStore.theme.colors.accentTint)
                .frame(width: fillWidth, height: thumbSize)
                .position(x: rtl ? size.width - padding - fillWidth / 2 : padding + fillWidth / 2,
                          y: size.height / 2)
            ForEach(0..<count, id: \.self) { index in
                let position = CGFloat(index) / CGFloat(count - 1)
                Group {
                    if index == 0 {
                        Text("A").scaledFont(.caption2.weight(.bold)).scaleEffect(scale)
                    } else {
                        Circle().frame(width: 5 * scale, height: 5 * scale)
                    }
                }
                .foregroundStyle(index <= selectedIndex ? Color.white.opacity(0.6) : Color.primary.opacity(0.35))
                .position(x: inset + travel * (rtl ? 1 - position : position), y: size.height / 2)
            }
            Circle()
                .fill(.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .position(x: thumbX, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? nil : .interactiveSpring(duration: 0.16), value: selectedIndex)
    }
}
