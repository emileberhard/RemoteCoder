import Observation
import PhotosUI
import SpeechKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ComposerPresentations {
    var editingAttachment: EditingTextAttachment?
    var showPhotoPicker = false
    #if os(iOS)
    var camera: CameraPresentation?

    struct CameraPresentation: Identifiable {
        let id = UUID()
        let screen: ChatScreenModel
        let draft: ComposerDraft
        var directory: URL { URL.temporaryDirectory.appending(path: "CameraCaptures/\(id)", directoryHint: .isDirectory) }
    }

    func presentCamera(for screen: ChatScreenModel, draft: ComposerDraft) {
        camera = CameraPresentation(screen: screen, draft: draft)
    }
    #endif
    var showFileImporter = false
    var showContextWindow = false
    var observationError: ObservationErrorDetails?

    struct ObservationErrorDetails: Identifiable {
        let id = UUID()
        let message: String
    }

    var blocksFocus: Bool {
        #if os(iOS)
        if camera != nil { return true }
        #endif
        return editingAttachment != nil || showPhotoPicker || showFileImporter || showContextWindow || observationError != nil
    }

    func dismiss() {
        editingAttachment = nil
        showPhotoPicker = false
        #if os(iOS)
        camera = nil
        #endif
        showFileImporter = false
        showContextWindow = false
        observationError = nil
    }
}

struct ChatComposerView: View {
    @Bindable var screen: ChatScreenModel
    let focus: ComposerFocus
    @Bindable var presentations: ComposerPresentations
    let onCancelComposerFocus: () -> Void
    let onOpenVoiceMode: (() -> Void)?
    let namespace: Namespace.ID
    let onOpenPendingQuestion: () -> Void
    let modelOptions: [ModelOption]
    let onSelectModel: (ModelOption) -> Void
    let onSend: (ChatScreenModel) async -> Bool
    let onQueue: (ChatScreenModel) async -> Bool
    let fileImportRequest: Int

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoDestination: AttachmentDestination?
    @State private var fileDestination: AttachmentDestination?
    @State private var focusAfterTakeOver = false
    @State private var isInputDropTargeted = false

    private struct AttachmentDestination {
        let screen: ChatScreenModel
        let draft: ComposerDraft
    }

    private var attachmentDestination: AttachmentDestination? {
        screen.currentDraft.map { AttachmentDestination(screen: screen, draft: $0) }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.isAttachmentDropTargeted) private var isSurfaceDropTargeted
    @Environment(AppThemeStore.self) private var themeStore
    private let recordingRed = Color(red: 0.85, green: 0.20, blue: 0.20)

    private enum LayoutMetrics {
        static let surfaceInset: CGFloat = 8
        static let inputSpacing: CGFloat = 2
        static let actionSpacing: CGFloat = 2
    }

    private enum Presentation: Equatable {
        case focused, compact, recording
    }

    private var presentation: Presentation {
        if screen.target.voice.isRecording { return .recording }
        #if os(iOS)
        return focus.wrappedValue ? .focused : .compact
        #else
        return .focused
        #endif
    }

    private var isCompact: Bool {
        presentation != .focused
    }

    private var surfaceCornerRadius: CGFloat {
        (isCompact ? 34 : 28) * interfaceScale
    }

    private var minimumInlineWidth: CGFloat {
        #if os(iOS)
        let maximumActionCount = 4 + (onOpenVoiceMode == nil ? 0 : 1)
        return ControlMetrics.minimumTarget * CGFloat(maximumActionCount + 1) * interfaceScale
            + LayoutMetrics.actionSpacing * CGFloat(maximumActionCount - 2)
            + LayoutMetrics.inputSpacing * 2
        #else
        let actionCount = 3 + (onOpenVoiceMode == nil ? 0 : 1)
            + (screen.contextWindowUsage == nil ? 0 : 1) + (screen.composerStopState == .hidden ? 0 : 1)
        let minimumPreviewWidth = 96 * interfaceScale
        return minimumPreviewWidth + 24 + ControlMetrics.minimumTarget * CGFloat(actionCount) * interfaceScale
            + LayoutMetrics.actionSpacing * CGFloat(actionCount - 1)
            + LayoutMetrics.inputSpacing * 2
        #endif
    }

    private var inputLayout: ComposerInputLayout {
        ComposerInputLayout(
            allowsInline: isCompact && !dynamicTypeSize.isAccessibilitySize,
            minimumInlineWidth: minimumInlineWidth,
            spacing: LayoutMetrics.inputSpacing
        )
    }

    var body: some View {
        ComposerSurfaceLayout(narrows: isCompact && !dynamicTypeSize.isAccessibilitySize,
                              minimumInlineWidth: minimumInlineWidth + LayoutMetrics.surfaceInset * 2) {
            composerSurface
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: presentation)
    }

    private var composerSurface: some View {
        VStack(spacing: 0) {
            if screen.isLoadingConversationSettings {
                ProgressView("Loading conversation settings…")
                    .scaledFont(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget)
            } else if let reason = screen.newChatModelUnavailableReason {
                UnresolvedModelControls(
                    reason: reason,
                    models: modelOptions,
                    selection: Binding(get: { screen.selectedModel }, set: { $0.map(onSelectModel) }),
                    retry: canRetryCodexModels ? { Task { await screen.target.refreshCodexModels() } } : nil
                )
                .padding(.horizontal, 12)
            } else if screen.areConversationSettingsReady, let selectedModel = screen.selectedModel {
                settingsControls(selectedModel)
            } else {
                Button("Retry conversation settings") {
                    if let thread = screen.activeConversation { screen.resumeConversation(thread) }
                }
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget)
                .buttonStyle(ResponsiveButtonStyle())
                .composerControlHitRegion()
            }
            ConversationSettingsStatus(screen: screen, threadID: screen.activeSessionID)
                .padding(.horizontal, 12)

            if let warning = screen.target.gatewayWarning {
                dismissibleNotice(warning.message) { screen.target.gatewayWarning = nil }
                    .accessibilityIdentifier("gateway-warning")
            }
            if let failure = screen.stopFailure {
                dismissibleNotice(failure) { screen.target.dismissStopFailure() }
                    .accessibilityIdentifier("stop-failure")
            }
            if let failure = screen.takeOverFailure {
                dismissibleNotice(failure) { screen.target.dismissTakeOverFailure() }
                    .accessibilityIdentifier("take-over-failure")
            }
            ConversationMetadataStatus(screen: screen)
                .padding(.horizontal, 12)

            if let error = screen.draftErrorMessage ?? screen.composerDocument?.errorMessage {
                ComposerDraftFailureNotice(message: error, retry: screen.draftErrorMessage == nil ? nil : { screen.retryDraft() })
            }
            if let prompt = screen.pendingQuestion {
                PendingQuestionBar(prompt: prompt, action: onOpenPendingQuestion)
                    .composerControlHitRegion()
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            attachmentStrip
            composerBar
                .disabled(screen.currentDraft == nil || !screen.drafts.acceptsInput)
        }
        .animation(reduceMotion ? nil : .smooth, value: screen.pendingQuestion?.itemID)
        .animation(reduceMotion ? nil : .smooth, value: attachmentStripState)
        .padding(.horizontal, LayoutMetrics.surfaceInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlass(.standard, in: .rect(cornerRadius: surfaceCornerRadius))
        .containerShape(.rect(cornerRadius: surfaceCornerRadius))
        .overlay { attachmentDropHighlight }
        .sheet(item: $presentations.editingAttachment) { editing in
            PastedTextEditor(text: editing.text) { text in
                editing.screen.updatePastedText(text, attachmentID: editing.attachmentID, in: editing.draft)
            }
        }
        // Above the glass so empty space receives taps, with actual control
        // bounds cut out so their native touch/selection handling stays intact.
        .overlayPreferenceValue(ComposerControlBounds.self) { anchors in
            GeometryReader { geometry in
                let surface = RoundedRectangle(cornerRadius: surfaceCornerRadius)
                    .path(in: CGRect(origin: .zero, size: geometry.size))
                let emptySpace = anchors.reduce(surface) { region, anchor in
                    region.subtracting(Path(geometry[anchor]))
                }
                Color.clear
                    .contentShape(emptySpace)
                    .onTapGesture(perform: focusInputFromSurfaceTap)
                    .allowsHitTesting(screen.currentDraft != nil && !screen.target.voice.isRecording)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $presentations.observationError) { details in
            NavigationStack {
                ScrollView {
                    Text(details.message)
                        .scaledFont(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Live updates error")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            HapticService.shared.play(.disclosure)
                            presentations.observationError = nil
                        }
                    }
                    ToolbarItemGroup(placement: .appBottom) {
                        Button("Copy full error", systemImage: "doc.on.doc") {
                            HapticService.shared.copy(details.message)
                        }
                        Spacer()
                        Button("Retry", systemImage: "arrow.clockwise") {
                            HapticService.shared.play(.buttonPress)
                            presentations.observationError = nil
                            if let threadID = screen.activeSessionID { screen.target.observation.retry(threadID: threadID) }
                        }
                    }
                }
            }
        }
        .alert(
            "Dictation",
            isPresented: Binding(
                get: { screen.target.voiceError != nil },
                set: { if !$0 { screen.target.voiceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(screen.target.voiceError ?? "")
        }
    }

    private var canRetryCodexModels: Bool {
        let catalog = screen.target.codexModels
        return catalog.catalog == nil && !catalog.isRefreshing
    }

    private func settingsControls(_ selectedModel: ModelOption) -> some View {
        ConversationSettingsControls(
            models: modelOptions,
            model: Binding(get: { selectedModel }, set: { onSelectModel($0) }),
            reasoning: reasoningSelection,
            fastMode: fastModeSelection
        ) {
            #if os(iOS)
            if let usage = screen.contextWindowUsage {
                contextWindowButton(usage)
                    .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
                    .foregroundStyle(.primary)
                    .composerControlHitRegion()
            }
            #endif
            observationStatusControl
        }
        .id(screen.transcriptIdentity)
    }

    private var observationStatusControl: some View {
        let state = screen.target.observation.state(of: screen.activeSessionID)
        #if os(iOS)
        let controlWidth: CGFloat = switch state {
        case .attaching, .catchingUp, .failed: ControlMetrics.minimumTarget
        default: 0
        }
        #else
        let controlWidth = ControlMetrics.minimumTarget
        #endif
        return ZStack {
            switch state {
            case .attaching, .catchingUp:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Catching up with live updates")
            case .failed(let message):
                Button {
                    dismissSoftwareKeyboard()
                    presentations.observationError = ComposerPresentations.ObservationErrorDetails(message: message)
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(.system(size: ComposerMetrics.iconSize - 2, weight: .semibold))
                        .foregroundStyle(.red)
                        .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
                .tooltip("Show live updates error")
                .accessibilityLabel("Live updates error")
                .accessibilityHint("Show full error details and retry options")
                .composerControlHitRegion()
            default:
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .scaledFrame(width: controlWidth, height: ControlMetrics.minimumTarget)
    }

    private var leadingActions: some View {
        HStack(spacing: LayoutMetrics.actionSpacing) {
            attachmentMenu
                .composerControlHitRegion()

            #if os(macOS)
            if let usage = screen.contextWindowUsage {
                contextWindowButton(usage)
                    .composerControlHitRegion()
            }
            #endif
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
        .foregroundStyle(.primary)
    }

    private var trailingActions: some View {
        HStack(spacing: LayoutMetrics.actionSpacing) {
            stopButton

            if let onOpenVoiceMode {
                SlideToConfirmButton(label: "Voice mode", verb: "call", symbol: "phone.fill", tint: .green,
                                     identifier: "composer-voice-mode") {
                    dismissSoftwareKeyboard()
                    Task { @MainActor in onOpenVoiceMode() }
                } face: {
                    composerIcon("phone.and.waveform")
                        .matchedTransitionSource(id: "voice-mode", in: namespace)
                }
                .tooltip("Voice mode")
                .composerControlHitRegion()
            }

            micButton
                .composerControlHitRegion()
            ComposerSendControl(screen: screen, send: sendMessage, queue: queueMessage)
                .composerControlHitRegion()
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
        .foregroundStyle(.primary)
        .animation(reduceMotion ? nil : .smooth, value: screen.composerStopState == .hidden)
    }

    @ViewBuilder
    private var stopButton: some View {
        if screen.composerStopState != .hidden {
            ComposerStopButton(state: screen.composerStopState, stop: screen.stopTurn)
                .composerControlHitRegion()
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private func dismissibleNotice(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(message).scaledFont(.footnote)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress))
                .labelStyle(.iconOnly)
                .frame(minWidth: ControlMetrics.minimumTarget, minHeight: ControlMetrics.minimumTarget)
                .tooltip("Dismiss")
                .composerControlHitRegion()
        }
        .padding(.horizontal, 12)
    }

    private func contextWindowButton(_ usage: ContextWindowUsage) -> some View {
        Button {
            dismissSoftwareKeyboard()
            presentations.showContextWindow = true
        } label: {
            CompactProgressRing(
                progress: usage.usedFraction,
                tint: usage.fillColor,
                diameter: ComposerMetrics.iconSize
            )
            .animation(reduceMotion ? nil : .smooth, value: usage)
            .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            .contentShape(.rect)
        }
        .tooltip("Context window")
        .accessibilityLabel("Context window")
        .accessibilityValue("\(usage.usedPercent) percent full, \(usage.tokensText)")
        .popover(isPresented: $presentations.showContextWindow, arrowEdge: .bottom) {
            ContextWindowPopover(usage: usage)
                .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
                .presentationSizing(.fitted)
        }
    }

    private var reasoningSelection: Binding<ReasoningSelection> {
        Binding(get: { screen.reasoningSelection }, set: {
            screen.selectReasoning($0, for: screen.activeSessionID)
        })
    }

    private var fastModeSelection: Binding<Bool?> {
        Binding(get: { screen.fastModeSelection }, set: {
            if let value = $0 { screen.selectFastMode(value, for: screen.activeSessionID) }
        })
    }

    private var attachmentMenu: some View {
        AppMenu(trigger: .icon) {
            #if os(iOS)
            Button {
                dismissSoftwareKeyboard()
                if let draft = screen.currentDraft { presentations.presentCamera(for: screen, draft: draft) }
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            #endif

            Button {
                dismissSoftwareKeyboard()
                photoDestination = attachmentDestination
                presentations.showPhotoPicker = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }

            Button {
                dismissSoftwareKeyboard()
                fileDestination = attachmentDestination
                presentations.showFileImporter = true
            } label: {
                Label("Choose File", systemImage: "doc")
            }

            Button(action: pasteFromClipboard) {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }

        } label: {
            composerIcon("plus")
        }
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .tooltip("Add attachment")
        .accessibilityLabel("Add attachment")
        .onChange(of: fileImportRequest) {
            dismissSoftwareKeyboard()
            fileDestination = attachmentDestination
            presentations.showFileImporter = true
        }
        .fileImporter(
            isPresented: $presentations.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard let destination = fileDestination, case .success(let urls) = result else { return }
            destination.screen.handlePickedFiles(urls, for: destination.draft)
        }
        .photosPicker(
            isPresented: $presentations.showPhotoPicker,
            selection: $photoSelection,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        #if os(iOS)
        .fullScreenCover(item: $presentations.camera, onDismiss: { focus.wrappedValue = true }) { capture in
            CameraCaptureView(directory: capture.directory, onDone: { files in
                try await CameraCaptureBatch.importFiles(files, from: capture.directory) { files in
                    guard capture.screen.target.acceptsWork, !Task.isCancelled else { throw CancellationError() }
                    capture.screen.importFiles(files.map { file in .inOwnDirectory { file } }, for: capture.draft)
                }
                presentations.camera = nil
            }, dismissal: .button {
                try await CameraCaptureBatch.discard(in: capture.directory)
                presentations.camera = nil
            })
        }
        #endif
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty, let destination = photoDestination else { return }
            photoSelection = []
            destination.screen.handlePickedMedia(items, for: destination.draft)
        }
    }

    private func composerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .scaledFont(.system(size: ComposerMetrics.iconSize))
            .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            .contentShape(.rect)
    }

    private var pendingImportCount: Int {
        guard let draft = screen.currentDraft else { return 0 }
        return screen.target.fileImports.pendingCount(for: draft.id)
    }

    private struct AttachmentStripState: Equatable {
        let tileIDs: [UUID]
        let pendingCount: Int
    }

    private var attachmentStripState: AttachmentStripState {
        AttachmentStripState(tileIDs: screen.recoverableDictations.map(\.id) + screen.composerAttachments.map(\.id),
                             pendingCount: pendingImportCount)
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        let pendingCount = pendingImportCount
        if !screen.recoverableDictations.isEmpty || !screen.composerAttachments.isEmpty || pendingCount > 0 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(0..<pendingCount, id: \.self) { _ in
                        PendingComposerImportTile()
                    }
                    ForEach(screen.recoverableDictations) { dictation in
                        RecoverableDictationTile(
                            dictation: dictation,
                            transcribeAction: { screen.transcribeRecoverableDictation(dictation.id) },
                            deleteAction: { screen.deleteRecoverableDictation(dictation.id) }
                        )
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    ForEach(screen.composerAttachments) { attachment in
                        if let content = ComposerMediaTile.Content(attachment.content) {
                            ComposerMediaTile(attachment: content,
                                stagedCopy: attachment.file.flatMap(screen.target.fileImports.stagedCopy),
                                uploadState: screen.fileUploads[attachment.id],
                                removeAction: { screen.removeAttachment(attachment) },
                                retryAction: { screen.retryUpload(attachment.id) })
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 8, for: .scrollContent)
            .scrollIndicators(.hidden)
            .environment(\.chatImageSource, ChatImageSource(screen: screen))
            .defaultScrollAnchor(.trailing, for: .sizeChanges)
            .animation(reduceMotion ? nil : .smooth,
                       value: attachmentStripState)
            .padding(.horizontal, -8)
            .composerControlHitRegion()
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }

    private var composerBar: some View {
        Group {
            if screen.target.voice.isRecording {
                recordingComposerBar
            } else {
                textComposerBar
            }
        }
    }

    private var isOpenInOtherClient: Bool { screen.currentConversationDispatchBlock == .otherClient }

    private var textComposerBar: some View {
        VStack(spacing: 0) {
            if isOpenInOtherClient {
                ComposerTakeOverPanel(
                    activity: screen.currentConversationActivity,
                    isTakingOver: screen.isTakingOverCurrentConversation,
                    takeOver: {
                        focusAfterTakeOver = true
                        screen.takeOverCurrentConversation()
                    }
                )
                .composerControlHitRegion()
                .padding(.top, 4)
                .transition(.blurReplace)
            } else {
                unlockedComposerBar
                    .transition(.blurReplace)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: isOpenInOtherClient)
        .onChange(of: isOpenInOtherClient) { _, locked in
            guard !locked, focusAfterTakeOver else { return }
            focusAfterTakeOver = false
            focus.wrappedValue = true
        }
        .onChange(of: screen.takeOverFailure) { _, failure in
            if failure != nil { focusAfterTakeOver = false }
        }
        .onChange(of: ComposerSends(screen)) { previous, current in
            if previous.screen == current.screen { dismissSoftwareKeyboard() }
        }
    }

    private var unlockedComposerBar: some View {
        VStack(spacing: 0) {
            if let block = screen.currentConversationDispatchBlock {
                HStack {
                    if let activity = screen.currentConversationActivity {
                        ConversationActivityIndicator(state: activity, style: .labeled)
                    }
                    Spacer()
                    Text(block.label)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            ComposerSlashCommandArea(screen: screen, focus: focus)
            inputLayout {
                leadingActions

                composerInput
                    .composerControlHitRegion()
                    .padding(.horizontal, 12)
                    .padding(.vertical, isCompact ? 0 : 10)
                    .frame(minWidth: isCompact ? ControlMetrics.minimumTarget * interfaceScale : nil,
                           maxWidth: .infinity, minHeight: ControlMetrics.minimumTarget * interfaceScale)
                    .accessibilityIdentifier("codex-composer-input")

                trailingActions
            }
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        if let document = screen.composerDocument {
            ComposerTextInput(document: document, prompt: inputPrompt, focus: focus,
                              actions: inputActions, maximumLines: isCompact ? 1 : 6)
                .id(document.id)
        } else {
            Text(inputPrompt).scaledFont(.body).foregroundStyle(.secondary)
        }
    }

    private var recordingComposerBar: some View {
        HStack(spacing: 10) {
            ComposerWaveformView(
                isActive: true,
                tint: .white,
                level: { screen.target.voice.readNormalizedLevel() }
            )
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.leading, 13)

            recordStopButton
        }
        .padding(4)
        .background(recordingRed, in: ConcentricRectangle())
    }

    private func focusInputFromSurfaceTap() {
        guard screen.currentDraft != nil, !screen.target.voice.isRecording else { return }
        focus.wrappedValue = true
    }

    private var recordStopButton: some View {
        Button {
            screen.micTapStopImmediate()
            Task { await screen.micTapStopAsync() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white)
                    .scaledFrame(width: ComposerMetrics.recordStopGlyphSize, height: ComposerMetrics.recordStopGlyphSize)
            }
            .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            .contentShape(Circle())
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: nil, pressedScale: 0.92, pressedOpacity: 0.9))
        .background(
            Circle().fill(.white.opacity(0.14))
        )
        .overlay(
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
        )
        .tooltip("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    private var micButton: some View {
        let isTranscribing = screen.target.voice.isTranscribing

        return Button {
            screen.micTapStart()
            dismissSoftwareKeyboard()
            Task { await screen.micTapStartAsync() }
        } label: {
            if isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            } else {
                composerIcon("mic")
            }
        }
        .disabled(isTranscribing)
        .tooltip(isTranscribing ? "Transcribing recording" : "Dictate")
        .accessibilityLabel(isTranscribing ? "Transcribing recording" : "Start recording")
    }

    private func pasteFromClipboard() {
        let shouldDefocus = screen.handlePasteFromClipboard(Pasteboard.composerPaste())
        if shouldDefocus && screen.composerDocument?.hasContent != true { dismissSoftwareKeyboard() }
    }

    private func dismissSoftwareKeyboard() {
        onCancelComposerFocus()
        focus.dismissSoftwareKeyboard()
    }

    private func sendMessage() {
        let origin = screen
        Task { @MainActor in _ = await onSend(origin) }
    }

    private func queueMessage() {
        Task { @MainActor in _ = await onQueue(screen) }
    }

    private var inputPrompt: String {
        if screen.canSteerCurrentConversation { return "Guide the next steps…" }
        return screen.currentAgentProvider == .claude ? "Message Claude…" : "Message Codex…"
    }

    private var inputActions: ComposerInputActions {
        ComposerInputActions(
            send: sendMessage,
            lastSentPrompt: { [screen] in SentPromptRecall.lastPrompt(in: screen.streamItems) },
            stop: stopRunningTurn,
            attach: { [screen] paste in _ = screen.attachPastedContent(paste) },
            openPastedText: { id in
                guard let draft = screen.currentDraft,
                      let entry = screen.composerDocument?.content.pasted.first(where: { $0.id == id }) else { return }
                dismissSoftwareKeyboard()
                presentations.editingAttachment = EditingTextAttachment(attachmentID: id, text: entry.text, draft: draft, screen: screen)
            },
            dropTargetChanged: { isInputDropTargeted = $0 }
        )
    }

    private func stopRunningTurn() -> Bool {
        guard case .ready(let turn) = screen.composerStopState else { return false }
        screen.stopTurn(turn)
        return true
    }

    private var attachmentDropHighlight: some View {
        let isTargeted = isSurfaceDropTargeted || isInputDropTargeted
        return RoundedRectangle(cornerRadius: surfaceCornerRadius)
            .strokeBorder(themeStore.theme.colors.accentTint, lineWidth: 2)
            .background(themeStore.theme.colors.accentTint.opacity(0.08), in: .rect(cornerRadius: surfaceCornerRadius))
            .opacity(isTargeted ? 1 : 0)
            .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isTargeted)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// Anchors resolve in the current layout, including keyboard and Dynamic Type
// changes. Subtraction, rather than even-odd holes, keeps overlaps excluded.
private struct ComposerControlBounds: PreferenceKey {
    nonisolated static var defaultValue: [Anchor<CGRect>] { [] }

    nonisolated static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reserves this control's bounds from the composer's empty-space focus target.
    func composerControlHitRegion() -> some View {
        anchorPreference(key: ComposerControlBounds.self, value: .bounds) { [$0] }
    }
}

private struct ContextWindowPopover: View {
    let usage: ContextWindowUsage
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
            Gauge(value: usage.usedFraction) { Text("Context window") }
                .gaugeStyle(.accessoryLinearCapacity)
                .labelsHidden()
                .tint(usage.fillColor)
                .accessibilityHidden(true)
            Text(usage.tokensText)
                .scaledFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Label("Compacts automatically when nearly full", systemImage: "rectangle.compress.vertical")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 280, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text("Context window").scaledFont(.subheadline)
    }

    private var value: some View {
        Text("\(usage.usedPercent)% full")
            .scaledFont(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(usage.fillColor)
            .contentTransition(.numericText())
    }
}

private extension ContextWindowUsage {
    var fillColor: Color {
        switch usedPercent {
        case 90...: .red
        case 75..<90: Color("UsageLow")
        default: .primary
        }
    }
}

private struct RecoverableDictationTile: View {
    let dictation: RecoverableDictation
    let transcribeAction: () -> Void
    let deleteAction: () -> Void
    @InterfaceScaledMetric(relativeTo: .caption) private var height: CGFloat = ComposerMetrics.attachmentTileHeight
    @State private var confirmsDeletion = false

    var body: some View {
        ComposerTile(height: height, removeLabel: "Delete recording", removeAction: { confirmsDeletion = true }) {
            Button(action: transcribeAction) {
                AttachmentTileSummary(symbol: "waveform", title: duration, maximumWidth: height * 2.6, truncation: .middle) {
                    status
                }
                .frame(width: height * 2.6)
                .contentShape(.rect)
            }
            .buttonStyle(ResponsiveButtonStyle())
        }
        .disabled(dictation.status == .transcribing)
        .confirmationDialog("Delete this recording?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive, action: deleteAction)
        } message: {
            Text("The audio is deleted and cannot be transcribed later.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, transcribeAction)
        .accessibilityActions {
            if dictation.status != .transcribing {
                Button("Delete") { confirmsDeletion = true }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch dictation.status {
        case .waiting:
            Text(savedState)
                .foregroundStyle(.secondary)
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .fontWeight(.semibold)
                Text("Tap to retry")
            }
            .foregroundStyle(.red)
        }
    }

    private var duration: String {
        dictation.recording.duration.formatted(.time(pattern: .minuteSecond))
    }

    private var savedState: String {
        dictation.recording.wasInterrupted ? "Interrupted" : "Not transcribed"
    }

    private var accessibilityLabel: String {
        let status = switch dictation.status {
        case .waiting: savedState
        case .transcribing: "Transcribing"
        case .failed(let message): "Transcription failed, \(message)"
        }
        return "Recording, \(duration), \(status)"
    }
}

struct ComposerTile<Content: View>: View {
    let height: CGFloat
    let removeLabel: String
    let removeAction: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: height)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) { removeButton }
    }

    private var removeButton: some View {
        Button(action: removeAction) {
            Image(systemName: "xmark")
                .scaledFont(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .scaledFrame(width: ComposerMetrics.removeBadgeDiameter, height: ComposerMetrics.removeBadgeDiameter)
                .background(.black.opacity(0.55), in: .circle)
                .padding(5)
                .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget, alignment: .topTrailing)
                .contentShape(.rect)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: nil))
        .tooltip(LocalizedStringKey(removeLabel))
        .accessibilityLabel(removeLabel)
    }
}

#if DEBUG
private enum ComposerPreviewState: String, CaseIterable {
    case folded, typing, draft
}

#Preview("Composer", arguments: ComposerPreviewState.allCases) { state in
    if let defaults = UserDefaults(suiteName: "RemoteCoder.ComposerPreview") {
        ChatComposerPreview(state: state, defaults: defaults)
    } else {
        Text("Could not create isolated preview preferences.")
    }
}

@MainActor
private struct ChatComposerPreview: View {
    let state: ComposerPreviewState
    @State private var screen: ChatScreenModel
    @State private var theme = AppThemeStore()
    @State private var presentations = ComposerPresentations()
    #if os(iOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif
    @Namespace private var namespace
    private let preferences: ModelPickerPreferences
    private static let voiceCalls = VoiceCallCenter()

    private var previewVoiceModeAction: (() -> Void)? {
        #if os(iOS)
        return {}
        #else
        return nil
        #endif
    }

    private static let model = ModelOption(
        id: "preview-codex", displayName: "GPT-6.1 Sol",
        reasoningEfforts: [.low, .medium, .high, .xhigh], supportsFastMode: true,
        supportsDaybreakBlue: false,
        acceptsImages: true, provider: .codex, isListed: true
    )

    init(state: ComposerPreviewState, defaults: UserDefaults) {
        self.state = state
        let preferences = ModelPickerPreferences(defaults: defaults)
        self.preferences = preferences
        #if os(iOS)
        let backgroundExecution = UIKitBackgroundExecution()
        #else
        let backgroundExecution = ForegroundOnlyBackgroundExecution()
        #endif
        let uploadContinuation = ForegroundUploadContinuation()
        let target = ChatTargetModel(
            chatDefaults: defaults, modelPickerPreferences: preferences,
            syncedPreferences: SyncedPreferenceStore(defaults: defaults, keys: []),
            voiceCalls: Self.voiceCalls, backgroundExecution: backgroundExecution, uploadContinuation: uploadContinuation,
            gatewayPolicy: .isolated,
            storage: HostStorage(root: URL.temporaryDirectory.appending(path: "RemoteCoderComposerPreview")),
            htmlVisuals: HTMLVisualServices(directory: URL.temporaryDirectory.appending(path: "RemoteCoderComposerPreview/html-visuals"))
        )
        let screen = ChatScreenModel(target: target, newChat: UUID())
        screen.selectModel(Self.model, for: nil)
        screen.selectReasoning(.effort(.high), for: nil)
        screen.selectFastMode(false, for: nil)
        if state == .draft {
            screen.input = "Make the composer more compact while reading, and expand it smoothly when I start typing."
        }
        _screen = State(initialValue: screen)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Tap the composer to expand it. Tap here to fold it.")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            }
            .onTapGesture { focused = false }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerView(
                    screen: screen, focus: $focused, presentations: presentations, onCancelComposerFocus: {},
                    onOpenVoiceMode: previewVoiceModeAction, namespace: namespace,
                    onOpenPendingQuestion: {}, modelOptions: [Self.model],
                    onSelectModel: { screen.selectModel($0, for: nil) },
                    onSend: { _ in false }, onQueue: { _ in false }, fileImportRequest: 0
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
                #if os(macOS)
                .padding(.bottom, 8)
                #else
                .padding(.bottom, focused ? 8 : 0)
                #endif
                .scaledFrame(maxWidth: ReadableContentWidth.composer)
                .frame(maxWidth: .infinity)
            }
            .background { ThemedAppBackground() }
            .navigationTitle("Composer Preview")
            .inlineNavigationTitle()
            .reasoningPickerOverlay()
        }
        .environment(preferences)
        .environment(theme)
        .task { focused = state == .typing }
    }
}
#endif

struct ComposerDraftFailureNotice: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).scaledFont(.footnote)
            if let retry {
                Button("Retry saving draft", action: retry)
                    .buttonStyle(ResponsiveButtonStyle())
                    .composerControlHitRegion()
            }
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityIdentifier("composer-draft-error")
    }
}

private struct ComposerSends: Equatable {
    let screen: ObjectIdentifier
    let count: Int

    @MainActor init(_ screen: ChatScreenModel) {
        self.screen = ObjectIdentifier(screen)
        count = screen.composerSends
    }
}
