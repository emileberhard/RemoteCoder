import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct HostImagePreview: Sendable {
    let image: DecodedImage
    let pixelSize: CGSize

    let byteCount: Int
}

enum HostImagePreviewError: LocalizedError {
    case undecodable

    var errorDescription: String? { "This image could not be decoded." }
}

@MainActor
final class HostImagePreviews {
    nonisolated static let maximumPixelSize = 1_600
    private static let cacheByteLimit = 48 << 20
    private static let cacheCountLimit = 24
    private nonisolated static let decodableTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    private let access: any HostFileAccess
    private let logger = AppLogger(category: "HostFiles")
    private var cache: [HostFileReference: HostImagePreview] = [:]
    private var recency: [HostFileReference] = []
    private var pixelSizes: [HostFileReference: CGSize] = [:]
    private var sizeRecency: [HostFileReference] = []
    private var queue: Task<Void, Never>?
    private var pendingCount = 0
    private var cacheGeneration = 0

    init(access: any HostFileAccess) {
        self.access = access
    }

    nonisolated static func canPreview(_ reference: HostFileReference) -> Bool {
        canPreview(name: reference.path)
    }

    nonisolated static func canPreview(name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .pdf) || decodableTypes.contains(type.identifier)
    }

    func cached(_ reference: HostFileReference) -> HostImagePreview? {
        cache[reference]
    }

    func releaseReusableCaches() {
        cacheGeneration += 1
        cache.removeAll()
        recency.removeAll()
    }

    func pixelSize(for reference: HostFileReference) -> CGSize? {
        guard let size = pixelSizes[reference] else { return nil }
        sizeRecency.removeAll { $0 == reference }
        sizeRecency.append(reference)
        return size
    }

    func preview(_ reference: HostFileReference) async throws -> HostImagePreview {
        try Task.checkCancellation()
        if let cached = cache[reference] { return cached }
        guard pendingCount < Self.cacheCountLimit else { throw HostFileError.busy }
        pendingCount += 1
        let generation = cacheGeneration
        let previous = queue
        let work = Task {
            defer { pendingCount -= 1 }
            await previous?.value
            try Task.checkCancellation()
            if let cached = cache[reference] { return cached }
            let started = ContinuousClock.now
            do {
                let lease = try await access.open(reference: reference, containingDirectory: nil) { _ in }
                let preview: HostImagePreview
                do {
                    preview = try await Self.decode(lease.url)
                } catch {
                    await access.release(lease)
                    throw error
                }
                await access.release(lease)
                try Task.checkCancellation()
                if generation == cacheGeneration { store(preview, for: reference) }
                logger.notice("image preview loaded type=\(reference.diagnosticType) bytes=\(lease.metadata.bytes) pixels=\(Int(preview.pixelSize.width))x\(Int(preview.pixelSize.height)) elapsed=\(started.elapsedMilliseconds)ms cached=\(self.cache.count)")
                return preview
            } catch {
                if !(error is CancellationError) {
                    logger.error("image preview failed type=\(reference.diagnosticType) elapsed=\(started.elapsedMilliseconds)ms reason=\(error.diagnosticReason)")
                }
                throw error
            }
        }
        queue = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func thumbnail(_ reference: HostFileReference, maxDimension: Int) async throws -> DecodedImage? {
        guard pendingCount < Self.cacheCountLimit else { throw HostFileError.busy }
        pendingCount += 1
        defer { pendingCount -= 1 }
        let lease = try await access.open(reference: reference, containingDirectory: nil) { _ in }
        let image: DecodedImage?
        do {
            image = try await ImagePreparation.shared.thumbnail(url: lease.url, maxDimension: maxDimension)
        } catch {
            await access.release(lease)
            throw error
        }
        await access.release(lease)
        try Task.checkCancellation()
        return image
    }

    private func store(_ preview: HostImagePreview, for reference: HostFileReference) {
        pixelSizes[reference] = preview.pixelSize
        sizeRecency.removeAll { $0 == reference }
        sizeRecency.append(reference)
        if sizeRecency.count > 256 { pixelSizes.removeValue(forKey: sizeRecency.removeFirst()) }
        cache[reference] = preview
        recency.removeAll { $0 == reference }
        recency.append(reference)
        var bytes = cache.values.reduce(0) { $0 + $1.byteCount }
        while recency.count > 1, bytes > Self.cacheByteLimit || recency.count > Self.cacheCountLimit {
            if let evicted = cache.removeValue(forKey: recency.removeFirst()) { bytes -= evicted.byteCount }
        }
    }

    @concurrent
    private static func decode(_ url: URL) async throws -> HostImagePreview {
        try Task.checkCancellation()
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
        guard let image = isPDF ? firstPage(of: url) : thumbnail(of: url) else {
            throw HostImagePreviewError.undecodable
        }
        try Task.checkCancellation()
        return HostImagePreview(image: DecodedImage.make(cgImage: image),
                                pixelSize: CGSize(width: image.width, height: image.height),
                                byteCount: image.bytesPerRow * image.height)
    }

    private nonisolated static func thumbnail(of url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func firstPage(of url: URL) -> CGImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = CGFloat(maximumPixelSize) / max(size.width, size.height, 1)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
