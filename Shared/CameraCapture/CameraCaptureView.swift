import AVFoundation
import AVKit
import SwiftUI

enum CameraCaptureDismissal {
    case system
    case button(@MainActor () async throws -> Void)

    var usesCloseButton: Bool {
        if case .button = self { true } else { false }
    }
}

struct CameraCaptureView: View {
    let onDone: @MainActor ([URL]) async throws -> Void
    let dismissal: CameraCaptureDismissal
    @State private var model: CameraCaptureModel
    @State private var reviewPresented = false
    @State private var pinchStart: Double?
    @Environment(\.scenePhase) private var scenePhase

    init(directory: URL, onDone: @escaping @MainActor ([URL]) async throws -> Void, dismissal: CameraCaptureDismissal) {
        _model = State(initialValue: CameraCaptureModel(directory: directory))
        self.onDone = onDone
        self.dismissal = dismissal
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar.frame(height: geometry.size.height * 0.1)
                CameraPreview(source: model.camera.preview, deviceID: model.configuration?.deviceID)
                    .overlay(alignment: .bottom) { lensButtons.padding(.bottom, 14) }
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            if pinchStart == nil { pinchStart = model.zoom }
                            if let pinchStart { model.setZoom(pinchStart * value.magnification) }
                        }
                        .onEnded { _ in pinchStart = nil })
                bottomBar.frame(minHeight: geometry.size.height * 0.23)
            }
        }
        .background(.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(dismissal.usesCloseButton)
        .onCameraCaptureEvent { event in
            if event.phase == .ended, !reviewPresented { model.takePhoto() }
        }
        .task(id: scenePhase == .background) {
            if scenePhase != .background { await model.run() }
        }
        .sheet(isPresented: $reviewPresented) { review }
    }

    private var topBar: some View {
        HStack {
            Button {
                let modes = model.configuration?.flashModes ?? []
                if let index = modes.firstIndex(of: model.flash), !modes.isEmpty { model.flash = modes[(index + 1) % modes.count] }
            } label: {
                Image(systemName: flashSymbol(model.flash)).font(.title2).frame(width: 48, height: 48)
            }
            .disabled((model.configuration?.flashModes.count ?? 0) <= 1 || !model.canEdit)
            .accessibilityLabel("Flash")
            .accessibilityValue(flashName(model.flash))
            Spacer()
            Button("Done") { model.finish(onDone: onDone) }
                .font(.headline).foregroundStyle(.yellow)
                .disabled(model.photos.isEmpty || !model.canEdit)
                .accessibilityIdentifier("camera-capture-done")
        }
        .padding(.horizontal, 24)
        .opacity(model.controlsFullscreen ? 0 : 1)
        .allowsHitTesting(!model.controlsFullscreen)
    }

    private var lensButtons: some View {
        HStack(spacing: 10) {
            if let configuration = model.configuration {
                ForEach(configuration.lenses, id: \.self) { factor in
                    let displayed = factor * configuration.displayMultiplier
                    let selected = abs(model.zoom - factor) < 0.05
                    Button { model.setZoom(factor) } label: {
                        Text(displayed.formatted(.number.precision(.fractionLength(0...1))) + (selected ? "×" : ""))
                            .font(.system(size: 16, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .yellow : .white)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(.black.opacity(selected ? 0.6 : 0.3), in: .circle)
                    }
                    .accessibilityLabel("\(displayed.formatted()) times zoom")
                    .disabled(!model.canEdit)
                }
            }
        }
        .opacity(model.controlsFullscreen ? 0 : 1)
        .allowsHitTesting(!model.controlsFullscreen)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let failure = model.failure ?? model.photos.compactMap(\.saveFailure).last {
                Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(3)
            }
            HStack {
                stackButton.frame(maxWidth: .infinity)
                Button { model.takePhoto() } label: {
                    Circle().fill(.white).padding(5)
                        .overlay { Circle().stroke(.white.opacity(0.5), lineWidth: 2) }
                        .frame(width: 76, height: 76)
                }
                .disabled(!model.canCapture)
                .accessibilityLabel("Take Photo")
                .accessibilityIdentifier("camera-capture-shutter")
                Group {
                    if model.isBusy || !model.isReady && model.failure == nil { ProgressView().tint(.white) }
                    else if model.photos.count >= CameraCaptureBatch.maximumPhotos { Text("\(CameraCaptureBatch.maximumPhotos) photo limit").font(.caption) }
                    else { Color.clear }
                }
                .frame(width: 76, height: 76).frame(maxWidth: .infinity)
            }
            HStack {
                if case .button(let onClose) = dismissal {
                    Button { model.close(onClose: onClose) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Camera")
                        .accessibilityIdentifier("camera-capture-close")
                } else { Color.clear.frame(width: 48, height: 48) }
                Spacer()
                Text("PHOTO").font(.headline).foregroundStyle(.yellow)
                Spacer()
                Button { model.flipCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                    .accessibilityLabel("Flip Camera")
                    .accessibilityIdentifier("camera-capture-flip")
            }
            .font(.title2)
            .buttonStyle(CameraRoundButtonStyle())
            .disabled(!model.canEdit)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .opacity(model.controlsFullscreen ? 0 : 1)
        .allowsHitTesting(!model.controlsFullscreen)
    }

    private var stackButton: some View {
        Button { reviewPresented = true } label: {
            ZStack(alignment: .bottomTrailing) {
                if let photo = model.photos.last {
                    photoThumbnail(photo).frame(width: 52, height: 52).clipped()
                        .clipShape(.rect(cornerRadius: 8))
                        .background {
                            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.2))
                                .frame(width: 50, height: 50).offset(x: 4, y: -4)
                        }
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.6)) }
                    Text("\(model.photos.count)").font(.caption.bold())
                        .padding(5).background(.black, in: .circle).offset(x: 6, y: 6)
                } else { Image(systemName: "square.stack").font(.title2).frame(width: 52, height: 52) }
            }
        }
        .disabled(model.photos.isEmpty || !model.canEdit)
        .accessibilityLabel("Review \(model.photos.count) photos")
        .accessibilityIdentifier("camera-capture-review")
    }

    private var review: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                    ForEach(model.photos) { photo in
                        CameraPhotoReview(file: photo.file, processing: model.processing)
                            .overlay(alignment: .topTrailing) {
                                Button("Remove Photo", systemImage: "minus.circle.fill") { model.remove(photo.id) }
                                    .labelStyle(.iconOnly).font(.title)
                                    .foregroundStyle(.white, .red).padding(8)
                                    .disabled(!model.canEdit)
                            }
                    }
                }.padding()
            }
            .navigationTitle("\(model.photos.count) Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back to Camera", systemImage: "chevron.left") { reviewPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onCameraCaptureEvent { _ in }
    }

    @ViewBuilder private func photoThumbnail(_ photo: CameraCapturedPhoto) -> some View {
        if let thumbnail = photo.thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() }
        else { Image(systemName: "photo").resizable().scaledToFit() }
    }

    private func flashName(_ mode: AVCaptureDevice.FlashMode) -> String {
        switch mode { case .auto: "Auto"; case .on: "On"; case .off: "Off"; @unknown default: "Unknown" }
    }

    private func flashSymbol(_ mode: AVCaptureDevice.FlashMode) -> String {
        switch mode { case .auto: "bolt.badge.a"; case .on: "bolt.fill"; case .off: "bolt.slash.fill"; @unknown default: "bolt.trianglebadge.exclamationmark" }
    }
}

private struct CameraRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 48, height: 48)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: .circle)
    }
}
