import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CameraCaptureModel {
    private(set) var configuration: CameraConfiguration?
    private(set) var zoom = 1.0
    private(set) var photos: [CameraCapturedPhoto] = []
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var controlsFullscreen = false
    private(set) var failure: String?
    private var pendingCaptures: Set<UUID> = []
    private var captureOrder: [UUID] = []
    var flash: AVCaptureDevice.FlashMode = .auto
    @ObservationIgnored let camera = CameraCaptureSession()
    @ObservationIgnored let processing = CameraPhotoProcessing()
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let tasks = OwnedTasks<Operation>()
    @ObservationIgnored private var generation: UUID?

    private enum Operation: Hashable { case capture(UUID), process(UUID), flip, zoom, selection, finish, close }

    init(directory: URL) { self.directory = directory }

    var canCapture: Bool { isReady && !isBusy && pendingCaptures.count < 2 && photos.count + pendingCaptures.count < CameraCaptureBatch.maximumPhotos }
    var canEdit: Bool { !isBusy && pendingCaptures.isEmpty }

    func run() async {
        let generation = UUID()
        self.generation = generation
        isReady = false
        tasks.cancelAll()
        await tasks.drain()
        guard self.generation == generation, !Task.isCancelled else { return }
        isBusy = false
        do {
            let updates = try await camera.start(generation: generation)
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            for await update in updates {
                guard !Task.isCancelled, self.generation == generation else { break }
                switch update {
                case .configuration(let configuration):
                    self.configuration = configuration
                    zoom = configuration.zoom
                    if !configuration.flashModes.contains(flash) { flash = .off }
                case .zoom(let zoom): self.zoom = zoom
                case .fullscreen(let fullscreen): controlsFullscreen = fullscreen
                case .ready(let ready): isReady = ready
                }
            }
        } catch is CancellationError {
        } catch { if self.generation == generation { failure = error.localizedDescription } }
        if self.generation == generation {
            isReady = false
            tasks.cancelAll()
        }
        await camera.stop(generation: generation)
        await tasks.drain()
        if self.generation == generation {
            self.generation = nil
            isBusy = false
        }
    }

    func takePhoto() {
        guard canCapture else { return }
        let id = UUID()
        let generation = generation
        pendingCaptures.insert(id)
        captureOrder.append(id)
        failure = nil
        tasks.start(.capture(id)) { [self] in
            defer { pendingCaptures.remove(id) }
            do {
                let photo = try await camera.takePhoto(id: id, into: directory, flash: flash)
                photos.append(photo)
                let order = captureOrder
                photos.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
                process(photo)
            } catch {
                captureOrder.removeAll { $0 == id }
                if !(error is CancellationError), self.generation == generation { failure = error.localizedDescription }
            }
        }
    }

    private func process(_ photo: CameraCapturedPhoto) {
        tasks.start(.process(photo.id)) { [self] in
            let thumbnail = await processing.thumbnail(photo.file, pixels: CameraPhotoProcessing.trayPixels)
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index].thumbnail = thumbnail }
            let failure = await processing.save(photo.file)
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index].saveFailure = failure }
        }
    }

    func setZoom(_ zoom: Double) {
        guard isReady, !tasks.isRunning(.flip), !tasks.isRunning(.finish) else { return }
        tasks.start(.zoom) { [self] in
            do { try await camera.setZoom(zoom) }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    func flipCamera() {
        guard isReady, canEdit else { return }
        isBusy = true
        let generation = generation
        tasks.start(.flip) { [self] in
            defer { if self.generation == generation { isBusy = false } }
            do { try await camera.flipCamera() }
            catch { if !Task.isCancelled, self.generation == generation { failure = error.localizedDescription } }
        }
    }

    func remove(_ id: UUID) {
        guard canEdit, let photo = photos.first(where: { $0.id == id }) else { return }
        isBusy = true
        tasks.start(.selection) { [self] in
            defer { isBusy = false }
            do {
                await tasks.value(.process(id))
                try Task.checkCancellation()
                try await CameraCaptureBatch.discardPhoto(photo.file)
                photos.removeAll { $0.id == id }
                captureOrder.removeAll { $0 == id }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    func finish(onDone: @escaping @MainActor ([URL]) async throws -> Void) {
        guard !photos.isEmpty, canEdit else { return }
        isBusy = true
        tasks.start(.finish) { [self] in
            defer { isBusy = false }
            do {
                for photo in photos { await tasks.value(.process(photo.id)) }
                try Task.checkCancellation()
                try await onDone(photos.map(\.file))
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }

    func close(onClose: @escaping @MainActor () async throws -> Void) {
        guard canEdit else { return }
        isBusy = true
        tasks.start(.close) { [self] in
            defer { isBusy = false }
            do {
                for photo in photos { await tasks.value(.process(photo.id)) }
                try Task.checkCancellation()
                try await onClose()
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
