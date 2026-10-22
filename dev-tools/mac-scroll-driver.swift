import AppKit
import CoreGraphics
import QuartzCore

struct Options {
    let pid: pid_t
    let seconds: Double
    let velocity: Double
    let swipeSeconds: Double
    let idleSeconds: Double
    let force: Bool

    init() throws {
        var values: [String: String] = [:]
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--force" {
                values[key] = "true"
                index += 1
            } else {
                guard ["--pid", "--seconds", "--velocity", "--swipe-seconds", "--idle-seconds"].contains(key),
                      index + 1 < arguments.count else {
                    throw DriverError("usage: mac-scroll-driver --pid PID --seconds N [--velocity 900] [--swipe-seconds 2] [--idle-seconds 10] [--force]")
                }
                values[key] = arguments[index + 1]
                index += 2
            }
        }
        guard let pid = Int32(values["--pid"] ?? ""), pid > 0,
              let seconds = Double(values["--seconds"] ?? ""), seconds.isFinite, seconds > 0, seconds <= 3600,
              let velocity = Double(values["--velocity"] ?? "900"), velocity.isFinite, velocity > 0,
              let swipe = Double(values["--swipe-seconds"] ?? "2"), swipe.isFinite, swipe >= 0.1,
              let idle = Double(values["--idle-seconds"] ?? "10"), idle.isFinite, idle >= 0 else {
            throw DriverError("pid and duration are required; numeric parameters must be finite and positive (idle may be zero, swipe >= 0.1s, duration <= 3600s)")
        }
        self.pid = pid
        self.seconds = seconds
        self.velocity = velocity
        swipeSeconds = swipe
        idleSeconds = idle
        force = values["--force"] != nil
    }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class ScrollDriver: NSObject {
    let options: Options
    let source: CGEventSource
    let point: CGPoint
    let windowID: Int
    let screen: NSScreen
    var initialIdle: Double
    var started = 0.0
    var startedAt = ""
    var previousElapsed = 0.0
    var gesture = -1
    var eventCount = 0
    var finished = false
    var failure: String?
    var displayCallbacks = 0

    init(options: Options) throws {
        guard CGPreflightPostEventAccess() else {
            throw DriverError("Post Event (Accessibility) permission is denied for \(CommandLine.arguments[0]) (pid \(getpid()), parent pid \(getppid())). Run it from a process that holds the permission; under SSH macOS attributes it to sshd, which must not be granted because every SSH session could then synthesize input. No permission prompt was requested.")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw DriverError("cannot create private event source")
        }
        let idle = Self.inputIdleSeconds()
        guard options.force || idle >= options.idleSeconds else {
            throw DriverError("HID idle time \(idle)s is below \(options.idleSeconds)s; leave the Mac idle or use --force (input abort remains enabled)")
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw DriverError("cannot read on-screen window geometry")
        }
        let candidates = windows.compactMap { window -> (CGRect, Int)? in
            guard window[kCGWindowOwnerPID as String] as? Int32 == options.pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 200, rect.height > 200,
                  let id = window[kCGWindowNumber as String] as? Int else { return nil }
            return (rect, id)
        }
        guard let (rect, id) = candidates.max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height }) else {
            throw DriverError("no visible main window for pid \(options.pid); open the transcript before recording")
        }
        let point = CGPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.45)
        guard let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayBounds(number.uint32Value).contains(point)
        }) else { throw DriverError("cannot identify the window's display") }
        self.options = options
        self.source = source
        self.point = point
        windowID = id
        self.screen = screen
        initialIdle = idle
    }

    static let inputTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged, .keyDown, .flagsChanged, .scrollWheel,
    ] + [18, 19, 20, 29, 30, 31].compactMap { CGEventType(rawValue: $0) }

    static func inputIdleSeconds() -> Double {
        inputTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    func post(pixels: Double, phase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else {
            failure = "cannot create scroll event"
            finished = true
            return
        }
        event.location = point
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pixels)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pixels)
        event.postToPid(options.pid)
        eventCount += 1
    }

    @objc func tick(_ link: CADisplayLink) {
        guard !finished else { return }
        let elapsed = CACurrentMediaTime() - started
        let idle = Self.inputIdleSeconds()
        if idle + 0.001 < initialIdle + elapsed {
            post(pixels: 0, phase: 4)
            failure = "real HID input arrived; scripted scroll aborted"
            finished = true
            return
        }
        guard kill(options.pid, 0) == 0 else {
            failure = "target process exited"
            finished = true
            return
        }
        let end = min(elapsed, options.seconds)
        var cursor = previousElapsed
        while cursor < end {
            let currentGesture = Int((cursor + 1e-9) / options.swipeSeconds)
            if gesture != currentGesture {
                if gesture >= 0 { post(pixels: 0, phase: 4) }
                gesture = currentGesture
                post(pixels: 0, phase: 1)
            }
            let segmentEnd = min(end, Double(currentGesture + 1) * options.swipeSeconds)
            let direction = currentGesture.isMultiple(of: 2) ? -1.0 : 1.0
            post(pixels: direction * options.velocity * (segmentEnd - cursor), phase: 2)
            cursor = segmentEnd
        }
        displayCallbacks += 1
        previousElapsed = end
        if elapsed >= options.seconds {
            post(pixels: 0, phase: 4)
            finished = true
        }
    }

    func abort(_ reason: String) {
        guard !finished else { return }
        if gesture >= 0 { post(pixels: 0, phase: 4) }
        failure = reason
        finished = true
    }

    func run() throws {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(screen.maximumFramesPerSecond), maximum: Float(screen.maximumFramesPerSecond), preferred: Float(screen.maximumFramesPerSecond))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        initialIdle = Self.inputIdleSeconds()
        guard options.force || initialIdle >= options.idleSeconds else { throw DriverError("Mac became active before scrolling; idle gate refused") }
        startedAt = formatter.string(from: Date())
        started = CACurrentMediaTime()
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { self.abort("signal \(number) interrupted the scripted scroll") } }
            source.resume()
            return source
        }
        link.add(to: .current, forMode: .default)
        defer {
            link.invalidate()
            signals.forEach { $0.cancel() }
        }
        while !finished {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            let elapsed = CACurrentMediaTime() - started
            let idle = Self.inputIdleSeconds()
            if !finished && idle + 0.001 < initialIdle + elapsed {
                post(pixels: 0, phase: 4)
                failure = "real HID input arrived; scripted scroll aborted"
                finished = true
            }
            if !finished && elapsed > options.seconds + 2 {
                post(pixels: 0, phase: 4)
                failure = "display link stalled"
                finished = true
            }
        }
        let receipt: [String: Any] = [
            "status": failure == nil ? "completed" : "aborted", "error": failure as Any? ?? NSNull(),
            "pid": options.pid, "windowID": windowID, "x": point.x, "y": point.y,
            "startedAt": startedAt, "endedAt": formatter.string(from: Date()),
            "seconds": options.seconds, "elapsedSeconds": CACurrentMediaTime() - started,
            "velocityPixelsPerSecond": options.velocity, "swipeSeconds": options.swipeSeconds,
            "idleThresholdSeconds": options.idleSeconds, "initialIdleSeconds": initialIdle, "force": options.force,
            "requestedHz": screen.maximumFramesPerSecond, "eventsPosted": eventCount,
            "displayCallbacks": displayCallbacks, "delivery": "pid", "pattern": "alternating-down-up"
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let failure { throw DriverError(failure) }
    }
}

do {
    try ScrollDriver(options: Options()).run()
} catch {
    FileHandle.standardError.write(Data("mac-scroll-driver: \(error)\n".utf8))
    exit(1)
}
