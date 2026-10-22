//
//  NotificationService.swift
//  RemoteCoderNotificationService
//
//

import Foundation
import Synchronization
import UserNotifications
import os.log

final class NotificationService: UNNotificationServiceExtension {
    private struct NotificationReply: @unchecked Sendable {
        let handler: (UNNotificationContent) -> Void
        let content: UNMutableNotificationContent
    }

    private struct Delivery {
        var reply: NotificationReply?
        var task: Task<Void, Never>?
    }

    private final class DeliveryState: Sendable {
        let value = Mutex(Delivery())
    }

    private let delivery = DeliveryState()
    private static let soundQueue = DispatchQueue(label: "RemoteCoder.NotificationService.sounds")
    private static let logger = Logger(subsystem: "RemoteCoder", category: "NotificationService")

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let origins = (Bundle.main.object(forInfoDictionaryKey: "RemoteCoderNotificationSoundOrigins") as? String ?? "")
            .split(whereSeparator: { $0.isWhitespace }).compactMap { URL(string: String($0)) }
        let rawURL = content.userInfo[RemoteCoderNotificationAudioKeys.url] as? String
        let audioFilename = content.userInfo[RemoteCoderNotificationAudioKeys.filename] as? String
        delivery.value.withLock { state in
            state.reply = NotificationReply(handler: contentHandler, content: content)
        }
        guard let rawURL, let filename = audioFilename,
              let url = URL(string: rawURL), NotificationSoundPolicy.acceptedFilename(filename) != nil,
              NotificationSoundPolicy.acceptsURL(url, origins: origins) else {
            Self.deliver(delivery, sound: nil)
            return
        }
        let delivery = delivery
        let appGroup = RemoteCoderAppGroup.identifier
        delivery.value.withLock { state in
            state.task = Task {
                do {
                    let data = try await Self.download(url, origins: origins)
                    try Task.checkCancellation()
                    guard NotificationSoundPolicy.acceptsAudio(data, filename: filename) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try Self.soundQueue.sync {
                        try Task.checkCancellation()
                        try Self.save(data, filename: filename, appGroup: appGroup)
                    }
                    Self.deliver(delivery, sound: filename)
                } catch {
                    Self.logger.error("Notification audio unavailable: \(error.localizedDescription, privacy: .public)")
                    Self.deliver(delivery, sound: nil)
                }
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.value.withLock { $0.task?.cancel() }
        Self.deliver(delivery, sound: nil)
    }

    private static func deliver(_ delivery: DeliveryState, sound: String?) {
        delivery.value.withLock { state in
            guard let reply = state.reply else { return }
            state.reply = nil
            state.task = nil
            if let sound { reply.content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: sound)) }
            reply.handler(reply.content)
        }
    }

    @concurrent private static func download(_ url: URL, origins: [URL]) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url, delegate: SoundRedirectPolicy(origins: origins))
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let finalURL = response.url, NotificationSoundPolicy.acceptsURL(finalURL, origins: origins),
              response.expectedContentLength <= NotificationSoundPolicy.maximumSoundBytes else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < NotificationSoundPolicy.maximumSoundBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private static func save(_ data: Data, filename: String, appGroup: String) throws {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = group.appendingPathComponent("Library/Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            let sounds = try urls.map { url in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
                return NotificationSoundPolicy.StoredSound(filename: url.lastPathComponent,
                    modifiedAt: values.contentModificationDate, byteCount: size)
            }
            for name in NotificationSoundPolicy.filenamesToRemove(sounds, retaining: filename) {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private final class SoundRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let origins: [URL]

    init(origins: [URL]) { self.origins = origins }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map { NotificationSoundPolicy.acceptsURL($0, origins: origins) } == true ? request : nil)
    }
}
