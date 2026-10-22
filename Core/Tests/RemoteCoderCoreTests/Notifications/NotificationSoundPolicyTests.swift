import Foundation
import Testing
@testable import RemoteCoderCore

struct NotificationSoundPolicyTests {
    @Test(arguments: ["../escape.caf", "folder/sound.caf", "folder\\sound.caf", "%2F.caf", ".caf", "sound.mp3"])
    func rejectsUnsafeSoundNames(_ name: String) {
        #expect(NotificationSoundPolicy.acceptedFilename(name) == nil)
    }

    @Test func acceptsSupportedSingleComponentNames() {
        #expect(NotificationSoundPolicy.acceptedFilename("alert-1.CAF") == "alert-1.CAF")
        #expect(NotificationSoundPolicy.acceptedFilename("alert.wav") == "alert.wav")
        #expect(NotificationSoundPolicy.acceptedFilename("alert.aiff") == "alert.aiff")
    }

    @Test func retainsTheNewestThirtyTwoAudioFiles() {
        let sounds = (0..<35).map { index in
            NotificationSoundPolicy.StoredSound(filename: "sound-\(index).caf",
                modifiedAt: Date(timeIntervalSince1970: Double(index)), byteCount: 32)
        } + [.init(filename: "memo.txt", modifiedAt: nil, byteCount: 0)]

        let removed = NotificationSoundPolicy.filenamesToRemove(sounds, retaining: "sound-34.caf")

        #expect(removed == ["memo.txt", "sound-0.caf", "sound-1.caf", "sound-2.caf"])
    }
    @Test func requiresConfiguredHTTPSOriginIncludingPort() throws {
        let origin = try #require(URL(string: "https://audio.example.com"))
        for value in ["http://audio.example.com/a.caf", "https://audio.example.com:8443/a.caf",
                      "https://audio.example.com.evil.test/a.caf", "https://user@audio.example.com/a.caf"] {
            #expect(!NotificationSoundPolicy.acceptsURL(try #require(URL(string: value)), origins: [origin]))
        }
        #expect(NotificationSoundPolicy.acceptsURL(try #require(URL(string: "https://audio.example.com:443/a.caf")), origins: [origin]))
        #expect(!NotificationSoundPolicy.acceptsURL(origin, origins: []))
    }

    @Test func cacheEvictsByBytesEvenBelowFileCountLimit() {
        let sounds = (0..<10).map { index in
            NotificationSoundPolicy.StoredSound(filename: "sound-\(index).caf",
                modifiedAt: Date(timeIntervalSince1970: Double(index)), byteCount: 4 * 1024 * 1024)
        }
        #expect(NotificationSoundPolicy.filenamesToRemove(sounds, retaining: "sound-9.caf") == ["sound-0.caf", "sound-1.caf"])
    }

    @Test func downloadedAudioMustMatchItsContainerAndByteLimit() {
        let wav = Data("RIFF0000WAVE".utf8)
        #expect(NotificationSoundPolicy.acceptsAudio(wav, filename: "a.wav"))
        #expect(!NotificationSoundPolicy.acceptsAudio(wav, filename: "a.caf"))
        #expect(!NotificationSoundPolicy.acceptsAudio(Data("<html>error</html>".utf8), filename: "a.wav"))
        #expect(!NotificationSoundPolicy.acceptsAudio(wav + Data(count: NotificationSoundPolicy.maximumSoundBytes), filename: "a.wav"))
    }

}
