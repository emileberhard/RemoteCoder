import SwiftUI

extension AgentProvider {
    var markImage: String { self == .claude ? "ClaudeMark" : "CodexMark" }

    var brandColor: Color {
        switch self {
        case .claude:
            Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex:
            Color(red: 0x7A / 255, green: 0x9D / 255, blue: 0xFF / 255)
        }
    }

    var markStyle: AnyShapeStyle {
        switch self {
        case .claude:
            AnyShapeStyle(brandColor)
        case .codex:
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xFF / 255),
                    Color(red: 0xC4 / 255, green: 0xD3 / 255, blue: 0xFF / 255),
                    brandColor,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }
}

struct UsageRingsControl: View {
    var workspace: ChatWorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ClaudeUsageRingButton(workspace: workspace, diameter: 36)
            UsageRingButton(workspace: workspace, diameter: 36)
        }
            .appGlass(.standard, in: .capsule, interactive: true)
    }
}

struct UsageRingButton: View {
    var workspace: ChatWorkspaceModel
    let diameter: CGFloat
    @State private var presentation: Presentation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Presentation {
        case usage, leavingUsageForAccounts, accounts
    }

    var body: some View {
        let account = workspace.codexAccount
        let rows = account?.sample.usageRows ?? []
        let status = workspace.providerStatus(of: .codex)
        Button(action: showUsage) {
            UsageRings(provider: .codex, rows: rows, status: status, diameter: diameter)
                .padding(4)
                .contentShape(.circle)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.96, pressedOpacity: 0.9))
        .tooltip("Show Codex usage")
        .accessibilityLabel("Codex usage, \(account?.title ?? "no account selected")")
        .accessibilityValue(UsageRings.accessibilityValue(rows: rows, status: status))
        .accessibilityIdentifier("usage-codex")
        .contextMenuPreviewShape(Circle())
        .contextMenu {
            Button("Show usage", systemImage: "chart.donut", action: showUsage)
            Button("Refresh usage", systemImage: "arrow.clockwise", action: refresh)
        } preview: {
            UsageDetailsView(workspace: workspace, onShowAllAccounts: {})
        }
        .popover(isPresented: isPresenting(.usage), arrowEdge: .top) {
            UsageDetailsView(workspace: workspace) {
                presentation = .leavingUsageForAccounts
            }
            .onDisappear {
                if presentation == .leavingUsageForAccounts { presentation = .accounts }
            }
            .presentationCompactAdaptation(horizontal: dynamicTypeSize.isAccessibilitySize ? .sheet : .popover, vertical: .sheet)
            .presentationDetents([.large])
            .presentationSizing(.fitted)
        }
        .accountsOverviewPresentation(isPresented: isPresenting(.accounts), workspace: workspace)
    }

    private func isPresenting(_ target: Presentation) -> Binding<Bool> {
        Binding(
            get: { presentation == target },
            set: { isPresented in
                if !isPresented, presentation == target { presentation = nil }
            }
        )
    }

    private func showUsage() {
        refresh()
        presentation = .usage
    }

    private func refresh() {
        Task { await workspace.accountDirectory.refreshCodex(interactive: true) }
    }
}

/// Native vector paths keep small rings sharp; only changed values animate.
/// Their colors/labels deliberately differ from HealthKit's Activity rings.
struct UsageRings: View {
    let provider: AgentProvider
    let diameter: CGFloat
    private let weekly: CodexUsageLimitRow?
    private let fiveHour: CodexUsageLimitRow?
    private let isBroken: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(provider: AgentProvider, rows: [CodexUsageLimitRow], status: ProviderStatus?, diameter: CGFloat) {
        self.provider = provider
        self.diameter = diameter
        weekly = rows.first { $0.kind == .weekly }
        fiveHour = rows.first { $0.kind == .fiveHour && $0.runOutWarning != nil }
        isBroken = status?.isBroken == true
    }

    static func accessibilityValue(rows: [CodexUsageLimitRow], status: ProviderStatus?) -> String {
        let usage = rows.isEmpty ? "Unavailable" : rows.map(\.ringAccessibilityValue).joined(separator: ". ")
        return status?.reason.map { "\($0). \(usage)" } ?? usage
    }

    var body: some View {
        let style = UsageRing.Style(lineWidth: contrast == .increased ? 4 : 3,
                                    trackOpacity: contrast == .increased ? 0.3 : 0.18,
                                    animation: reduceMotion ? nil : .smooth(duration: 0.35))
        ZStack {
            UsageRing(row: weekly, color: weekly?.remainingColor ?? .secondary, style: style)
            if let fiveHour, let warning = fiveHour.runOutWarning {
                UsageRing(row: fiveHour, color: fiveHour.isStale ? .secondary : warning.color, style: style)
                    .padding(style.lineWidth + 1)
                    .transition(.opacity)
            }
            Image(provider.markImage)
                .resizable()
                .scaledToFit()
                .foregroundStyle(provider.markStyle)
                .frame(width: diameter * 0.46, height: diameter * 0.46)
                .opacity(isBroken ? 0.3 : weekly.map { $0.isStale ? 0.5 : 1 } ?? 0.5)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .topTrailing) {
            if isBroken {
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.multicolor)
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
                    .offset(x: diameter * 0.08, y: -diameter * 0.04)
            }
        }
        .animation(style.animation, value: fiveHour?.runOutWarning)
        .accessibilityHidden(true)
    }
}

private struct UsageRing: View {
    struct Style {
        let lineWidth: CGFloat
        let trackOpacity: Double
        let animation: Animation?
    }

    let row: CodexUsageLimitRow?
    let color: Color
    let style: Style

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(style.trackOpacity), style: StrokeStyle(lineWidth: style.lineWidth, dash: row == nil ? [2, 3] : []))
            if let row {
                Circle()
                    .inset(by: style.lineWidth / 2)
                    .trim(from: 0, to: Double(row.remainingPercent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(row.isStale ? 0.5 : 1)
                    .animation(style.animation, value: row.remainingPercent)
            }
        }
    }
}

struct UsageDetailsView: View {
    var workspace: ChatWorkspaceModel
    let onShowAllAccounts: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.frame(maxHeight: 620)
        }
        .frame(idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 280,
               maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 280)
    }

    private var content: some View {
        let account = workspace.codexAccount
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: onShowAllAccounts) {
                Label(account?.title ?? "Codex", systemImage: "person.2")
                    .scaledFont(.headline)
            }
            .buttonStyle(.plain)
            AccountResetCount(resets: account?.sample.resets, isStale: account?.sample.stale ?? false)
            if let reason = workspace.providerStatus(of: .codex)?.reason {
                ProviderWarningLabel(text: reason).scaledFont(.footnote)
            }
            UsageDetailsContent(
                rows: account?.sample.usageRows ?? [],
                notice: account?.sample.usageNotice,
                isLoading: workspace.accountDirectory.hosts.contains(where: \.isRefreshing)
            )
        }
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 6)
    }
}

struct ProviderWarningLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UsageDetailsContent: View {
    let rows: [CodexUsageLimitRow]
    let notice: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice {
                Text(notice)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rows.isEmpty, notice == nil {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Usage unavailable").scaledFont(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(rows.sorted { $0.kind.rawValue < $1.kind.rawValue }) { row in UsageLimitRowView(row: row) }
        }
    }
}

struct UsageLimitRowView: View {
    let row: CodexUsageLimitRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                title
                value
            } else {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    value
                }
            }
            Gauge(value: Double(row.remainingPercent), in: 0...100) { Text(row.title) }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .tint(row.remainingColor)
                .opacity(row.isStale ? 0.5 : 1)
                .accessibilityHidden(true)
            if let resetText = row.resetText {
                Text(resetText).scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title) allowance")
        .accessibilityValue("\(row.remainingPercent) percent left\(row.isStale ? ", last known" : ""). \(row.resetText ?? "")")
    }

    private var title: some View {
        Text(row.title).scaledFont(.subheadline)
    }

    private var value: some View {
        Text("\(row.remainingPercent)% left")
            .scaledFont(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(row.remainingColor)
            .contentTransition(.numericText())
    }
}

extension CodexUsageLimitRow {
    var remainingColor: Color {
        if isStale { return .secondary }
        switch remainingPercent {
        case 0...10: return .red
        case 11...25: return Color("UsageLow")
        default: return .primary
        }
    }

    var ringAccessibilityValue: String {
        var value = "\(title): \(remainingPercent) percent left\(isStale ? ", last known" : "")"
        if let runOutWarning {
            let lead = Duration.seconds(runOutWarning.lead).formatted(.units(allowed: [.hours, .minutes], width: .wide, fractionalPart: .hide(rounded: .up)))
            value += ", on pace to run out \(lead) before it resets"
        }
        return value
    }
}

extension UsageRunOutWarning {
    private static let lime = (hue: 80.0, saturation: 0.85, brightness: 0.92)
    private static let orange = (hue: 32.0, saturation: 1.0, brightness: 1.0)
    private static let alert = (hue: 3.0, saturation: 0.82, brightness: 1.0)

    var color: Color {
        let (from, to, fraction) = severity < 0.5
            ? (Self.lime, Self.orange, severity * 2)
            : (Self.orange, Self.alert, (severity - 0.5) * 2)
        func blend(_ start: Double, _ end: Double) -> Double { start + (end - start) * fraction }
        return Color(hue: blend(from.hue, to.hue) / 360,
                     saturation: blend(from.saturation, to.saturation),
                     brightness: blend(from.brightness, to.brightness))
    }
}
