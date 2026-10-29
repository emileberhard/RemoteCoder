import CryptoKit
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct HTMLVisualRendererTests {
    private static let webContent = HTMLVisualWebContent()
    private let html = "<body><div id='content' style='height:80px'>Content</div></body>"
    private let theme = HTMLVisualTheme(fontSize: 17, text: "black", secondaryText: "gray",
        background: "white", surface: "white", accent: "blue", isDark: false)

    @Test
    func capturedImageAcceptsExactlyEightMiBAndRejectsOneAdditionalByte() throws {
        let key = HTMLVisualLayoutKey(digest: String(repeating: "a", count: 64), width: 320, theme: theme)
        let bytes = Data(repeating: 37, count: 8 << 20)
        let captured = try #require(HTMLVisualCapturedImage(data: bytes, key: key, revision: 1))
        #expect(captured.data == bytes)
        #expect(captured.key == key)
        #expect(HTMLVisualCapturedImage(data: Data(count: (8 << 20) + 1), key: key, revision: 1) == nil)
    }

    @Test
    func persistedImageRestoresCanonicalSnapshotAfterTurnover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = HTMLVisualPresentationCache(directory: directory, clock: ContinuousClock())
        let key = HTMLVisualLayoutKey(digest: String(repeating: "a", count: 64), width: 320, theme: theme)
        let bytes = Data([1, 2, 3])
        _ = try await cache.store(key, height: 80, image: bytes)
        let renderer = HTMLVisualRenderer(cache: cache, webContent: Self.webContent)
        await renderer.load()
        let evicted = renderer.snapshot(for: key)
        for width in 321...352 {
            _ = renderer.snapshot(for: HTMLVisualLayoutKey(digest: key.digest, width: width, theme: theme))
        }
        let restored = await renderer.restoreImage(for: key)
        #expect(restored !== evicted)
        #expect(restored === renderer.snapshot(for: key))
        #expect(restored.image == bytes)
        #expect(restored.height == 80)
        try await cache.retire()
        try await Self.remove(directory)
    }

    @Test(.timeLimit(.minutes(1)))
    func identicalInlineOccurrencesKeepIndependentLiveFrames() async throws {
        try await withFixture { fixture in
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let sourceFile = fixture.directory.appending(path: "source.html")
            try await Self.write(html, to: sourceFile)
            _ = try await documents.store(hostID: hostID, reference: fixture.reference, source: sourceFile)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let visibility = TranscriptVisibility()
            visibility.setVisibleRowIDs(["first", "second"])
            let controller = UIHostingController(rootView:
                ScrollView {
                    VStack(spacing: 12) {
                        HTMLVisualInline(url: fixture.url, title: "First")
                            .environment(\.transcriptRowVisibility, TranscriptRowVisibility(rowID: "first", visibility: visibility))
                        HTMLVisualInline(url: fixture.url, title: "Second")
                            .environment(\.transcriptRowVisibility, TranscriptRowVisibility(rowID: "second", visibility: visibility))
                    }
                    .frame(width: 320)
                }
                .environment(\.htmlVisualSource, source)
                .environment(\.htmlVisualTheme, theme)
                .environment(\.htmlVisualCaptureAllowed, false)
                .environment(\.scenePhase, .active)
                .environment(AppThemeStore()))
            fixture.window.show(controller)
            do {
                try await wait {
                    let pages = webViews(in: controller.view)
                    return pages.count == 2 && pages.allSatisfy { abs($0.bounds.height - 80) < 1 }
                }
                let pages = webViews(in: controller.view).sorted {
                    $0.convert($0.bounds, to: controller.view).minY < $1.convert($1.bounds, to: controller.view).minY
                }
                let first = try #require(pages.first)
                let second = try #require(pages.last)
                try await first.evaluateJavaScript("document.getElementById('content').style.height='240px';")
                try await wait { abs(first.bounds.height - 240) < 1 }
                #expect(abs(second.bounds.height - 80) < 1)
                try await second.evaluateJavaScript("document.getElementById('content').style.height='40px';")
                try await wait { abs(second.bounds.height - 40) < 1 }
                #expect(abs(first.bounds.height - 240) < 1)
            } catch {
                visibility.setVisibleRowIDs([])
                fixture.window.close()
                await store.retire()
                throw error
            }
            visibility.setVisibleRowIDs([])
            try await wait { webViews(in: controller.view).isEmpty }
            fixture.window.close()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func inlineMotionPreservesDocumentAndPinsAndDefersNewAdmissions(captureInitiallyAllowed: Bool) async throws {
        try await withFixture { fixture in
            let html = "<body><div style='height:80px'><input id='input'><span>Motion content</span></div><script>window.loads=(window.loads||0)+1;</script></body>"
            let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = try #require(URL(string: "rc-visual:" + digest))
            let reference = try #require(HTMLVisualReference(url: url))
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let sourceFile = fixture.directory.appending(path: "motion.html")
            try await Self.write(html, to: sourceFile)
            _ = try await documents.store(hostID: hostID, reference: reference, source: sourceFile)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let motion = InlineMotionFixture()
            motion.visibility.setVisibleRowIDs(["first"])
            let controller = UIHostingController(rootView: InlineMotionView(fixture: motion, url: url)
                .frame(width: 320)
                .environment(\.htmlVisualSource, source)
                .environment(\.htmlVisualTheme, theme)
                .environment(\.htmlVisualCaptureAllowed, captureInitiallyAllowed)
                .environment(\.scenePhase, .active)
                .environment(AppThemeStore()))
            fixture.window.show(controller)
            do {
                let key = HTMLVisualLayoutKey(digest: digest, width: 320, theme: theme)
                try await wait {
                    webViews(in: controller.view).count == 1
                        && webViews(in: controller.view).first?.bounds.height == 80
                        && webViews(in: controller.view).first.map { effectiveOpacity(of: $0) > 0.99 } == true
                        && (!captureInitiallyAllowed || fixture.renderer.snapshot(for: key).image != nil)
                }
                let original = try #require(webViews(in: controller.view).first)
                let originalBounds = original.bounds
                if !captureInitiallyAllowed { #expect(fixture.renderer.snapshot(for: key).image == nil) }
                _ = try await original.evaluateJavaScript("document.getElementById('input').value='Retained input';window.motionToken='retained';")

                motion.visibility.setScrollPhase(.tracking)
                try await wait { motion.observedScrolling == true && motion.observedMoving == false }
                #expect(webViews(in: controller.view).first === original)
                #expect(original.window != nil)
                #expect(effectiveOpacity(of: original) > 0.99)

                motion.visibility.setVisibleRowIDs(["first", "second"])
                motion.showSecond = true
                try await wait { motion.secondAppeared }
                _ = try await original.callAsyncJavaScript("await new Promise(resolve=>setTimeout(resolve,100)); return true;", in: nil, contentWorld: .page)
                #expect(webViews(in: controller.view).count == 1)

                motion.visibility.setScrollPhase(.decelerating)
                try await wait {
                    motion.observedMoving == true
                        && (captureInitiallyAllowed ? effectiveOpacity(of: original) == 0 : effectiveOpacity(of: original) > 0.99)
                }
                #expect(original.window != nil)
                #expect(original.bounds == originalBounds)
                #expect(try await original.evaluateJavaScript("window.motionToken") as? String == "retained")

                _ = try await original.callAsyncJavaScript("await new Promise(resolve=>setTimeout(resolve,100)); return true;", in: nil, contentWorld: .page)
                #expect(webViews(in: controller.view).count == 1)
                #expect(webViews(in: controller.view).first === original)
                #expect(original.bounds == originalBounds)

                motion.visibility.setScrollPhase(.idle)
                try await wait {
                    motion.observedScrolling == false && webViews(in: controller.view).count == 2
                        && effectiveOpacity(of: original) > 0.99
                }
                let reattached = webViews(in: controller.view)
                #expect(reattached.contains { $0 === original })
                #expect(try await original.evaluateJavaScript("document.getElementById('input').value") as? String == "Retained input")
                #expect(try await original.evaluateJavaScript("window.motionToken") as? String == "retained")
                #expect(try await original.evaluateJavaScript("window.loads") as? Int == 1)

                _ = try await original.callAsyncJavaScript("document.getElementById('input').focus();await new Promise(resolve=>setTimeout(resolve,0)); return true;", in: nil, contentWorld: .page)
                motion.visibility.setScrollPhase(.decelerating)
                try await wait { motion.observedMoving == true && effectiveOpacity(of: original) > 0.99 }
                #expect(webViews(in: controller.view).contains { $0 === original })
                #expect(original.window != nil)
                #expect(original.bounds == originalBounds)
                #expect(try await original.evaluateJavaScript("document.activeElement.id") as? String == "input")

                _ = try await original.callAsyncJavaScript("document.getElementById('input').blur();await new Promise(resolve=>setTimeout(resolve,0)); return true;", in: nil, contentWorld: .page)
                if captureInitiallyAllowed { try await wait { effectiveOpacity(of: original) == 0 } }
                else { #expect(effectiveOpacity(of: original) > 0.99) }
                motion.visibility.setScrollPhase(.idle)
                try await wait { webViews(in: controller.view).count == 2 && effectiveOpacity(of: original) > 0.99 }
                #expect(webViews(in: controller.view).contains { $0 === original })
                #expect(try await original.evaluateJavaScript("window.motionToken") as? String == "retained")
                #expect(try await original.evaluateJavaScript("window.loads") as? Int == 1)
            } catch {
                motion.visibility.setVisibleRowIDs([])
                fixture.window.close()
                await store.retire()
                throw error
            }
            motion.visibility.setVisibleRowIDs([])
            try await wait { webViews(in: controller.view).isEmpty }
            fixture.window.close()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationMakesAVisualPresentableBeforeItMountsAndReleasesItsPage() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                let reference = host.references[0]
                host.preparation.updateLayoutContext { $0.width = 320 }
                let key = HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme)
                let preparation = Task {
                    await host.preparation.awaitPresentable([reference], documents: host.source.documents, atMost: .seconds(8))
                }
                try await wait { host.preparation.surface.instance?.page != nil }
                weak let page = host.preparation.surface.instance?.page
                #expect(await preparation.value)
                let prepared = try #require(fixture.renderer.presentableRaster(for: key, displayScale: 3))
                #expect(prepared.raster.displayHeight == 80)
                #expect(fixture.renderer.height(for: key) == 80)
                try await wait { webViews(in: host.view).isEmpty && page == nil }
                #expect(await !host.preparation.awaitPresentable([reference], documents: host.source.documents,
                                                                atMost: .seconds(1)))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationInterruptedByAWidthChangeEndsPresentableAtTheNewWidth() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                let reference = host.references[0]
                host.preparation.updateLayoutContext { $0.width = 320 }
                let opening = Task {
                    await host.preparation.awaitPresentable([reference], documents: host.source.documents, atMost: .seconds(8))
                }
                try await wait { webViews(in: host.view).count == 1 }
                host.preparation.updateLayoutContext { $0.width = 400 }
                let key = HTMLVisualLayoutKey(digest: reference.digest, width: 400, theme: theme)
                let started = ContinuousClock.now
                _ = await opening.value
                #expect(ContinuousClock.now - started < .seconds(4))
                #expect(fixture.renderer.presentableRaster(for: key, displayScale: 3) != nil)
                #expect(fixture.renderer.height(for: key) == 80)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aVisualThatCannotBePreparedNoLongerHoldsReadinessWaits() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                host.preparation.updateLayoutContext { $0.width = 320 }
                let url = try #require(URL(string: "rc-visual:\(String(repeating: "a", count: 64))"))
                let unavailable = try #require(HTMLVisualReference(url: url))
                #expect(await host.preparation.awaitPresentable([unavailable], documents: host.source.documents,
                                                               atMost: .seconds(8)))
                #expect(await !host.preparation.awaitPresentable([unavailable], documents: host.source.documents,
                                                                atMost: .seconds(8)))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func eachWindowPreparesOnItsOwnPageAndAPreparationRendersInOneHost() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { first in
                let reference = first.references[0]
                let documents = first.source.documents
                let second = HTMLVisualSource(hostID: first.source.hostID, documents: documents, renderer: fixture.renderer,
                    preparation: HTMLVisualPreparation(renderer: fixture.renderer))
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let secondWindow = HostedWindow(scene: scene)
                let duplicateWindow = HostedWindow(scene: scene)
                let secondHost = UIHostingController(rootView: preparationHost(second))
                let duplicateHost = UIHostingController(rootView: preparationHost(first.source))
                secondWindow.show(secondHost)
                duplicateWindow.show(duplicateHost)
                defer {
                    secondWindow.close()
                    duplicateWindow.close()
                }
                try await wait { second.preparation.layoutContext.displayScale != nil }

                first.preparation.updateLayoutContext { $0.width = 320 }
                second.preparation.updateLayoutContext { $0.width = 400 }
                let firstWait = Task { await first.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8)) }
                let secondWait = Task { await second.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8)) }
                var rendered = (first: 0, second: 0, duplicate: 0)
                while !first.preparation.isPresentable(reference) || !second.preparation.isPresentable(reference) {
                    rendered.first = max(rendered.first, webViews(in: first.view).count)
                    rendered.second = max(rendered.second, webViews(in: secondHost.view).count)
                    rendered.duplicate = max(rendered.duplicate, webViews(in: duplicateHost.view).count)
                    try await Task.sleep(for: .milliseconds(5))
                }
                _ = await (firstWait.value, secondWait.value)
                #expect(rendered.first == 1)
                #expect(rendered.second == 1)
                #expect(rendered.duplicate == 0)
                #expect(fixture.renderer.height(for: HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme)) == 80)
                #expect(fixture.renderer.height(for: HTMLVisualLayoutKey(digest: reference.digest, width: 400, theme: theme)) == 80)

                first.preparation.updateLayoutContext { $0.width = 360 }
                second.preparation.updateLayoutContext { $0.width = 440 }
                let continuing = Task { await first.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8)) }
                let stopped = Task { await second.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8)) }
                try await wait { second.preparation.surface.instance != nil }
                second.preparation.setActive(false, conservesEnergy: false)
                #expect(await stopped.value)
                #expect(await continuing.value)
                #expect(first.preparation.isPresentable(reference))

                try await wait { webViews(in: secondHost.view).isEmpty }
                secondWindow.close()
                duplicateWindow.close()
                first.preparation.updateLayoutContext { $0.width = 300 }
                await first.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8))
                #expect(first.preparation.isPresentable(reference))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDemandEndsWaitsAndReleasesThePreparationPage() async throws {
        try await withFixture { fixture in
            let held = try Self.reference("<body>held</body>")
            try await withPreparationHost(fixture, documents: [], access: RendererHoldingAccess()) { host in
                host.preparation.updateLayoutContext { $0.width = 320 }
                let waiting = Task {
                    await host.preparation.awaitPresentable([held], documents: host.source.documents, atMost: .seconds(30))
                }
                try await wait { host.preparation.surface.instance != nil }
                let started = ContinuousClock.now
                host.preparation.cancelDemand()
                #expect(await waiting.value)
                #expect(ContinuousClock.now - started < .seconds(1))
                try await wait { host.preparation.surface.instance == nil }
                try await Task.sleep(for: .milliseconds(300))
                #expect(host.preparation.surface.instance == nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reactivatingDuringAWaitResumesPreparationFromCurrentState() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                let reference = host.references[0]
                host.preparation.updateLayoutContext { $0.width = 320 }
                let interrupted = Task {
                    await host.preparation.awaitPresentable([reference], documents: host.source.documents, atMost: .seconds(30))
                }
                try await wait { host.preparation.surface.instance != nil }
                host.preparation.setActive(false, conservesEnergy: false)
                host.preparation.setActive(true, conservesEnergy: false)
                let started = ContinuousClock.now
                #expect(await interrupted.value)
                #expect(ContinuousClock.now - started < .seconds(1))
                await host.preparation.awaitPresentable([reference], documents: host.source.documents, atMost: .seconds(8))
                #expect(host.preparation.isPresentable(reference))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedWarmDemandDoesNotDisplaceADistinctVisualAndNeverDecodes() async throws {
        let other = "<body><div id='content' style='height:120px'>Other</div></body>"
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: [html, other]) { host in
                host.preparation.updateLayoutContext { $0.width = 320 }
                let (repeated, distinct) = (host.references[0], host.references[1])
                host.preparation.warm(Array(repeating: repeated, count: 40) + [distinct], documents: host.source.documents)
                try await wait {
                    fixture.renderer.height(for: HTMLVisualLayoutKey(digest: distinct.digest, width: 320, theme: theme)) == 120
                }
                #expect(!host.preparation.isPresentable(distinct))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func energyConservationPreparesAwaitedVisualsButNotSpeculativeOnes() async throws {
        let measured = "<body><div id='content' style='height:100px'>Measured</div></body>"
        let other = "<body><div id='content' style='height:120px'>Other</div></body>"
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: [html, measured, other]) { host in
                let (required, geometry, speculative) = (host.references[0], host.references[1], host.references[2])
                let height = { (reference: HTMLVisualReference) in
                    fixture.renderer.height(for: HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme))
                }
                host.preparation.updateLayoutContext { $0.width = 320 }
                host.preparation.setActive(true, conservesEnergy: true)
                host.preparation.warm([speculative], documents: host.source.documents)
                #expect(host.preparation.surface.instance == nil)
                await host.preparation.awaitPresentable([required], documents: host.source.documents, atMost: .seconds(8))
                #expect(host.preparation.isPresentable(required))
                await host.preparation.awaitMeasured([geometry], documents: host.source.documents, atMost: .seconds(8))
                #expect(height(geometry) == 100)
                #expect(!host.preparation.isPresentable(geometry))
                #expect(height(speculative) == nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aLongVisualBecomesPresentableAtAReadableScaleWithinTheRetainedBudget() async throws {
        let long = "<body style='margin:0'><div id='content' style='height:7000px'>Long</div></body>"
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: [long]) { host in
                let reference = host.references[0]
                host.preparation.updateLayoutContext { $0.width = 402 }
                await host.preparation.awaitPresentable([reference], documents: host.source.documents, atMost: .seconds(8))
                let key = HTMLVisualLayoutKey(digest: reference.digest, width: 402, theme: theme)
                let prepared = try #require(fixture.renderer.presentableRaster(for: key, displayScale: 3))
                let reservation = prepared.raster.reservation
                #expect(prepared.raster.displayHeight == HTMLVisualInlineHeight.maximumPoints)
                #expect(reservation.width * reservation.height <= HTMLVisualRasterBudget.maximumImagePixels)
                #expect(Double(reservation.width) >= 402 * 1.8)
                #expect(Double(reservation.height) >= HTMLVisualInlineHeight.maximumPoints * 1.8)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func longVisualDemandFitsTheBudgetNearestFirstAndNeverEvictsHeldRasters() async throws {
        let documents = ["A", "B", "C", "D", "E"].map {
            "<body style='margin:0'><div id='content' style='height:7000px'>Long \($0)</div></body>"
        }
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: documents) { host in
                host.preparation.updateLayoutContext { $0.width = 402 }
                let references = host.references
                let measured = { (index: Int) in
                    fixture.renderer.height(for: HTMLVisualLayoutKey(digest: references[index].digest, width: 402, theme: theme)) != nil
                }
                let presentable = { (index: Int) in host.preparation.isPresentable(references[index]) }
                let raster = { (index: Int) in
                    fixture.renderer.presentableRaster(for: HTMLVisualLayoutKey(digest: references[index].digest, width: 402,
                        theme: theme), displayScale: 3)
                }

                await host.preparation.awaitPresentable(references, documents: host.source.documents, atMost: .seconds(30))
                #expect((0..<5).map(presentable) == [true, true, true, false, false])
                #expect((0..<5).allSatisfy(measured))

                var held = [raster(0), raster(1)]
                host.preparation.updateNear(Array(references[2...]), documents: host.source.documents)
                try await wait { presentable(3) }
                await host.preparation.awaitPresentable([references[4]], documents: host.source.documents, atMost: .seconds(8))
                #expect(!presentable(4))
                #expect(raster(0) != nil && raster(1) != nil)

                held.removeAll()
                host.preparation.updateNear(Array(references[2...]), documents: host.source.documents)
                try await wait { presentable(4) }
                #expect((2..<5).allSatisfy(presentable))
                #expect(!presentable(0) || !presentable(1))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rasterRetentionKeepsTheNewestRevisionAndRetainsNothingForCancelledWork() async throws {
        try await withFixture { fixture in
            let key = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 320, theme: theme)
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 80)).pdfData { context in
                context.beginPage()
                UIColor.systemTeal.setFill()
                context.fill(context.pdfContextBounds)
            }
            let older = try #require(HTMLVisualCapturedImage(data: pdf, key: key, revision: 1))
            let newer = try #require(HTMLVisualCapturedImage(data: pdf, key: key, revision: 2))
            #expect(await fixture.renderer.preparedRaster(for: newer, displayScale: 2) != nil)
            #expect(await fixture.renderer.preparedRaster(for: older, displayScale: 2) != nil)
            #expect(fixture.renderer.presentableRaster(for: newer, displayScale: 2) != nil)
            #expect(fixture.renderer.presentableRaster(for: older, displayScale: 2) == nil)

            let latest = try #require(HTMLVisualCapturedImage(data: pdf, key: key, revision: 3))
            let cancelled = Task { await fixture.renderer.preparedRaster(for: latest, displayScale: 2) }
            cancelled.cancel()
            #expect(await cancelled.value == nil)
            #expect(fixture.renderer.presentableRaster(for: latest, displayScale: 2) == nil)
            #expect(fixture.renderer.presentableRaster(for: newer, displayScale: 2) != nil)
        }
    }

    @Test
    func memoryPressureReleasesOnlyUnusedRasters() async throws {
        try await withFixture { fixture in
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 1_000)).pdfData { context in
                context.beginPage()
                UIColor.systemTeal.setFill()
                context.fill(context.pdfContextBounds)
            }
            let keys = (320...322).map { HTMLVisualLayoutKey(digest: fixture.reference.digest, width: $0, theme: theme) }
            var held: HTMLVisualPreparedRaster?
            weak var unused: HTMLVisualPreparedRaster?
            for (index, key) in keys.enumerated() {
                let capture = try #require(HTMLVisualCapturedImage(data: pdf, key: key, revision: 1))
                let prepared = try #require(await fixture.renderer.preparedRaster(for: capture, displayScale: 2))
                if index == 0 { held = prepared }
                if index == 2 { unused = prepared }
            }
            fixture.renderer.pinRasters([keys[1]])
            #expect(unused != nil)
            fixture.renderer.releaseReusableCaches()
            #expect(unused == nil)
            #expect(fixture.renderer.presentableRaster(for: keys[0], displayScale: 2) === held)
            #expect(fixture.renderer.presentableRaster(for: keys[1], displayScale: 2) != nil)
            held = nil
            fixture.renderer.unpinRasters([keys[1]])
            fixture.renderer.releaseReusableCaches()
            #expect(keys.allSatisfy { fixture.renderer.presentableRaster(for: $0, displayScale: 2) == nil })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sharpRastersBeatTheBaseScaleWithinOneBoundedBudget() async throws {
        try await withFixture { fixture in
            let tall = { (width: Double) in
                UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 6_000)).pdfData { context in
                    context.beginPage()
                    UIColor.systemTeal.setFill()
                    context.fill(context.pdfContextBounds)
                }
            }
            let key = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 390, theme: theme)
            let capture = try #require(HTMLVisualCapturedImage(data: tall(390), key: key, revision: 1))
            let base = try #require(await fixture.renderer.preparedRaster(for: capture, displayScale: 3))
            #expect(base.raster.reservation.scale < 2)

            var sharp = await fixture.renderer.sharpRaster(for: base, capture: capture, displayScale: 3)
            #expect(sharp?.sharpens(base) == true)
            #expect((sharp?.raster.reservation.scale ?? 0) > 2.6)
            #expect(sharp?.raster.displayHeight == 6_000)
            #expect(await fixture.renderer.sharpRaster(for: base, capture: capture, displayScale: 3) === sharp)

            let otherKey = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 391, theme: theme)
            let other = try #require(HTMLVisualCapturedImage(data: tall(391), key: otherKey, revision: 2))
            let otherBase = try #require(await fixture.renderer.preparedRaster(for: other, displayScale: 3))
            #expect(await fixture.renderer.sharpRaster(for: otherBase, capture: other, displayScale: 3) == nil)
            sharp = nil
            #expect(await fixture.renderer.sharpRaster(for: otherBase, capture: other, displayScale: 3) != nil)

            #expect(await fixture.renderer.sharpRaster(for: base, capture: nil, displayScale: 3) == nil)
            let cancelled = Task { await fixture.renderer.sharpRaster(for: base, capture: capture, displayScale: 3) }
            await Task.yield()
            cancelled.cancel()
            await Task.yield()
            await Task.yield()
            let replacement = await fixture.renderer.sharpRaster(for: base, capture: capture, displayScale: 3)
            #expect(await cancelled.value == nil)
            #expect(replacement?.sharpens(base) == true)
            let full = try #require(await fixture.renderer.preparedRaster(for: capture, displayScale: 1))
            #expect(await fixture.renderer.sharpRaster(for: full, capture: capture, displayScale: 1) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewerStoredCaptureStaysVisibleUntilPreparationReplacesItsRaster() async throws {
        let orange = UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        let azure = UIColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                let reference = host.references[0]
                let documents = host.source.documents
                let key = HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme)
                host.preparation.updateLayoutContext { $0.width = 320 }
                await host.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8))
                let captured = try #require(fixture.renderer.presentableRaster(for: key, displayScale: 3))
                #expect(!Self.matches(Self.centerColor(of: captured), Self.centerColor(of: orange)))

                let newer = try #require(fixture.renderer.store(Self.filledPDF(orange), for: key, height: 80))
                #expect(fixture.renderer.presentableRaster(for: key, displayScale: 3) === captured)
                #expect(!host.preparation.isPresentable(reference))
                host.preparation.updateNear([reference], documents: documents)
                try await wait { host.preparation.isPresentable(reference) }
                let near = try #require(fixture.renderer.presentableRaster(for: key, displayScale: 3))
                #expect(near.revision == newer.revision)
                #expect(Self.matches(Self.centerColor(of: near), Self.centerColor(of: orange)))

                let latest = try #require(fixture.renderer.store(Self.filledPDF(azure), for: key, height: 80))
                await host.preparation.awaitPresentable([reference], documents: documents, atMost: .seconds(8))
                let opened = try #require(fixture.renderer.currentRaster(for: key, displayScale: 3))
                #expect(opened.revision == latest.revision)
                #expect(Self.matches(Self.centerColor(of: opened), Self.centerColor(of: azure)))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func energyConservationAdmitsOnePreparationPageAcrossWindowsBeforeAnyVisualMounts() async throws {
        let other = "<body><div id='content' style='height:120px'>Other</div></body>"
        let conserving = AppEnergyPolicy(isLowPowerModeEnabled: true, thermalState: .nominal)
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: [html, other], energyPolicy: conserving) { first in
                let documents = first.source.documents
                let (own, others) = (first.references[0], first.references[1])
                let second = HTMLVisualSource(hostID: first.source.hostID, documents: documents, renderer: fixture.renderer,
                    preparation: HTMLVisualPreparation(renderer: fixture.renderer))
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let secondWindow = HostedWindow(scene: scene)
                let secondHost = UIHostingController(rootView: preparationHost(second, energyPolicy: conserving))
                secondWindow.show(secondHost)
                defer { secondWindow.close() }
                try await wait { second.preparation.layoutContext.displayScale != nil }

                first.preparation.updateLayoutContext { $0.width = 320 }
                second.preparation.updateLayoutContext { $0.width = 320 }
                let firstWait = Task { await first.preparation.awaitPresentable([own], documents: documents, atMost: .seconds(8)) }
                let secondWait = Task { await second.preparation.awaitPresentable([others], documents: documents, atMost: .seconds(8)) }
                var concurrent = 0
                let deadline = ContinuousClock.now + .seconds(16)
                while !first.preparation.isPresentable(own) || !second.preparation.isPresentable(others),
                      ContinuousClock.now < deadline {
                    concurrent = max(concurrent, webViews(in: first.view).count + webViews(in: secondHost.view).count)
                    try await Task.sleep(for: .milliseconds(5))
                }
                _ = await (firstWait.value, secondWait.value)
                #expect(first.preparation.isPresentable(own) && second.preparation.isPresentable(others))
                #expect(concurrent == 1)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundReadinessReportsUsableContextEdgesWithoutClearingNearDemand() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture) { host in
                let preparation = host.preparation
                var readinessEvents = 0
                preparation.onBackgroundPreparationReady = { readinessEvents += 1 }
                #expect(preparation.backgroundPreparationContext == nil)
                preparation.updateLayoutContext { $0.width = 320 }
                #expect(preparation.backgroundPreparationContext?.width == 320)
                #expect(readinessEvents == 1)
                preparation.updateNear(host.references, documents: host.source.documents)
                preparation.setActive(false, conservesEnergy: false)
                #expect(preparation.backgroundPreparationContext == nil)
                preparation.setActive(true, conservesEnergy: false)
                preparation.setActive(true, conservesEnergy: false)
                #expect(readinessEvents == 2)
                preparation.setActive(true, conservesEnergy: true)
                #expect(preparation.backgroundPreparationContext == nil)
                preparation.setActive(true, conservesEnergy: false)
                preparation.updateLayoutContext { $0.width = 360 }
                #expect(readinessEvents == 4)
                try await wait { host.references.allSatisfy(preparation.isPresentable) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBackgroundPreparationPreservesNearViewportPreparation() async throws {
        try await withFixture { fixture in
            try await withPreparationHost(fixture, access: RendererHoldingAccess()) { host in
                let preparation = host.preparation
                preparation.updateLayoutContext { $0.width = 320 }
                let held = try Self.reference("<body>held background</body>")
                let background = Task { await preparation.prepareInBackground([held], documents: host.source.documents) }
                try await wait { preparation.surface.instance != nil }
                preparation.updateNear(host.references, documents: host.source.documents)
                background.cancel()
                #expect(await background.value == .interrupted)
                try await wait { host.references.allSatisfy(preparation.isPresentable) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundPreparationStoresEveryVisualAcrossChunksAndThenHasNothingLeft() async throws {
        let documents = (0..<18).map { "<body><div id='content' style='height:\(40 + $0)px'>\($0)</div></body>" }
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: documents) { host in
                host.preparation.updateLayoutContext { $0.width = 320 }
                #expect(await host.preparation.prepareInBackground(host.references, documents: host.source.documents)
                    == .settled(stored: 18, unpreparable: 0))
                for (index, reference) in host.references.enumerated() {
                    #expect(fixture.renderer.height(for: HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme))
                        == Double(40 + index))
                }
                #expect(await host.preparation.prepareInBackground(host.references, documents: host.source.documents)
                    == .settled(stored: 18, unpreparable: 0))
                #expect(host.preparation.surface.instance == nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundPreparationPausesForInteractionAndResumesAfterInterruptions() async throws {
        let documents = (0..<5).map { "<body><div id='content' style='height:\(60 + $0)px'>\($0)</div></body>" }
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: documents) { host in
                let preparation = host.preparation
                let references = host.references
                preparation.updateLayoutContext { $0.width = 320 }
                let start = { (subset: [HTMLVisualReference]) in
                    Task { await preparation.prepareInBackground(subset, documents: host.source.documents) }
                }

                let paused = start([references[0], references[1]])
                try await wait { preparation.surface.instance != nil }
                preparation.setInteracting(true)
                try await wait { preparation.surface.instance == nil }
                try await Task.sleep(for: .milliseconds(300))
                #expect(preparation.surface.instance == nil)
                preparation.setInteracting(false)
                #expect(await paused.value == .settled(stored: 2, unpreparable: 0))

                let switched = start([references[2]])
                try await wait { preparation.surface.instance != nil }
                preparation.cancelDemand()
                #expect(await switched.value == .interrupted)
                try await wait { preparation.surface.instance == nil }

                let conserved = start([references[2]])
                try await wait { preparation.surface.instance != nil }
                preparation.setActive(true, conservesEnergy: true)
                #expect(await conserved.value == .interrupted)
                try await wait { preparation.surface.instance == nil }
                preparation.setActive(true, conservesEnergy: false)

                let resized = start([references[3]])
                try await wait { preparation.surface.instance != nil }
                preparation.updateLayoutContext { $0.width = 360 }
                #expect(await resized.value == .interrupted)
                try await wait { preparation.surface.instance == nil }

                #expect(await preparation.prepareInBackground(references, documents: host.source.documents)
                    == .settled(stored: 5, unpreparable: 0))
                for reference in references {
                    #expect(fixture.renderer.height(for: HTMLVisualLayoutKey(digest: reference.digest, width: 360, theme: theme)) != nil)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anExplicitFailureSettlesAsUnpreparable() async throws {
        let missing = try Self.reference("<body>missing</body>")
        try await withFixture { fixture in
            try await withPreparationHost(fixture, documents: []) { host in
                host.preparation.updateLayoutContext { $0.width = 320 }
                #expect(await host.preparation.prepareInBackground([missing], documents: host.source.documents)
                    == .settled(stored: 0, unpreparable: 1))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func consecutiveTimeoutsReleaseAdmissionWithoutPublishingLate() async throws {
        let access = RendererHoldingAccess()
        let deadline = RendererPageDeadline()
        let held = try (0..<4).map { try Self.reference("<body>held \($0)</body>") }
        try await withFixture { fixture in
            let preparation = HTMLVisualPreparation(renderer: fixture.renderer, pageDeadline: { try await deadline.wait() })
            try await withPreparationHost(fixture, access: access, preparation: preparation) { host in
                preparation.updateLayoutContext { $0.width = 320 }
                for reference in held {
                    let attempt = Task { await preparation.prepareInBackground([reference], documents: host.source.documents) }
                    await access.waitForRead(reference)
                    let instance = try #require(preparation.surface.instance)
                    try #require(instance.requestID != nil)
                    await deadline.waitUntilArmed()
                    await deadline.fire()
                    #expect(await attempt.value == .incomplete(missing: 1))
                    #expect(instance.requestID == nil && instance.page == nil && instance.activity == nil)
                    #expect(preparation.surface.instance == nil)
                    #expect(await access.cancelled.contains(reference))
                }
                let healthy = try #require(host.references.first)
                #expect(await preparation.prepareInBackground([healthy], documents: host.source.documents)
                    == .settled(stored: 1, unpreparable: 0))
                #expect(fixture.renderer.height(for: HTMLVisualLayoutKey(digest: healthy.digest, width: 320, theme: theme)) == 80)
                for reference in held {
                    let key = HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme)
                    #expect(fixture.renderer.height(for: key) == nil && !fixture.renderer.hasStoredSnapshot(for: key))
                }
                #expect(await access.cancelled == Set(held))
            }
        }
    }

    private struct PreparationHost {
        let source: HTMLVisualSource
        let references: [HTMLVisualReference]
        let view: UIView
        var preparation: HTMLVisualPreparation { source.preparation }
    }

    private func withPreparationHost(_ fixture: RendererLifecycleFixture, documents: [String]? = nil,
                                     access: any HostFileAccess = RendererCacheOnlyAccess(),
                                     energyPolicy: AppEnergyPolicy = Self.unconstrained,
                                     preparation: HTMLVisualPreparation? = nil,
                                     _ operation: (PreparationHost) async throws -> Void) async throws {
        let hostID = UUID()
        let cache = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents-\(UUID().uuidString)"),
            writer: HTMLVisualDocumentFileWriter())
        var references: [HTMLVisualReference] = []
        for document in documents ?? [html] {
            let reference = try Self.reference(document)
            let file = fixture.directory.appending(path: "source-\(UUID().uuidString).html")
            try await Self.write(document, to: file)
            _ = try await cache.store(hostID: hostID, reference: reference, source: file)
            references.append(reference)
        }
        let store = HTMLVisualDocumentStore(hostID: hostID, access: access, cache: cache)
        let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
            preparation: preparation ?? HTMLVisualPreparation(renderer: fixture.renderer))
        let controller = UIHostingController(rootView: preparationHost(source, energyPolicy: energyPolicy))
        fixture.window.show(controller)
        do {
            try await wait { source.preparation.layoutContext.theme != nil && source.preparation.layoutContext.displayScale != nil }
            try await operation(PreparationHost(source: source, references: references, view: controller.view))
        } catch {
            fixture.window.close()
            await store.retire()
            throw error
        }
        fixture.window.close()
        await store.retire()
    }

    private static let unconstrained = AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .nominal)

    private func preparationHost(_ source: HTMLVisualSource, energyPolicy: AppEnergyPolicy = Self.unconstrained) -> some View {
        HTMLVisualPreparationHost()
            .environment(\.htmlVisualSource, source)
            .environment(\.appEnergyPolicy, energyPolicy)
            .environment(\.htmlVisualTheme, theme)
            .environment(\.displayScale, 3)
            .environment(\.scenePhase, .active)
            .environment(AppThemeStore())
    }

    private static func filledPDF(_ color: UIColor) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 80)).pdfData { context in
            context.beginPage()
            color.setFill()
            context.fill(context.pdfContextBounds)
        }
    }

    private static func centerColor(of color: UIColor) -> [UInt8] {
        centerColor(of: UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.cgImage)
    }

    private static func centerColor(of prepared: HTMLVisualPreparedRaster) -> [UInt8] {
        centerColor(of: prepared.raster.image)
    }

    private static func centerColor(of image: CGImage?) -> [UInt8] {
        guard let image else { return [] }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: -Double(image.width / 2), y: -Double(image.height / 2),
                width: Double(image.width), height: Double(image.height)))
        }
        return pixel
    }

    private static func matches(_ color: [UInt8], _ expected: [UInt8]) -> Bool {
        color.count == expected.count && zip(color, expected).allSatisfy { abs(Int($0) - Int($1)) <= 24 }
    }

    private static func reference(_ html: String) throws -> HTMLVisualReference {
        let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = try #require(URL(string: "rc-visual:" + digest))
        return try #require(HTMLVisualReference(url: url))
    }

    @Test(.timeLimit(.minutes(1)), .enabled { await MainActor.run { UIDevice.current.userInterfaceIdiom == .phone } }, arguments: [80, 6_000])
    func occurrenceVisibilityGatesFirstAdmissionWhileNearPreparationAndAdmittedStateSurvive(height: Int) async throws {
        try await withFixture { fixture in
            let html = "<body style='margin:0'><div style='height:\(height)px'><input id='input'><span id='selection'>Retained selection</span></div></body>"
            let reference = try Self.reference(html)
            let url = try #require(URL(string: "rc-visual:" + reference.digest))
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let file = fixture.directory.appending(path: "occurrence.html")
            try await Self.write(html, to: file)
            _ = try await documents.store(hostID: hostID, reference: reference, source: file)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let scroll = InlineOccurrenceFixture()
            scroll.visibility.setVisibleRowIDs(["same-message"])
            let controller = UIHostingController(rootView: InlineOccurrenceView(fixture: scroll, url: url)
                .environment(\.htmlVisualSource, source)
                .environment(\.htmlVisualTheme, theme)
                .environment(\.htmlVisualCaptureAllowed, false)
                .environment(\.scenePhase, .active)
                .environment(AppThemeStore())
                .overlay { preparationHost(source) })
            fixture.window.show(controller)
            do {
                try await wait { source.preparation.layoutContext.displayScale != nil && scroll.scroll != nil }
                source.preparation.updateLayoutContext { $0.width = 320 }
                let key = HTMLVisualLayoutKey(digest: reference.digest, width: 320, theme: theme)
                source.preparation.updateNear([reference], documents: store)
                try await wait {
                    source.preparation.isPresentable(reference) && source.preparation.surface.instance == nil
                        && webViews(in: controller.view).isEmpty
                        && scroll.instance.admissionDemand?.occurrenceVisible == false
                }
                #expect(fixture.renderer.height(for: key) == Double(height))
                #expect(scroll.instance.admissionDemand?.active == false)
                #expect(scroll.instance.requestID == nil)

                scroll.scroll?("visual")
                try await wait {
                    webViews(in: controller.view).first?.bounds.height == CGFloat(height)
                        && webViews(in: controller.view).first.map { effectiveOpacity(of: $0) > 0.99 } == true
                }
                let original = try #require(webViews(in: controller.view).first)
                let viewport = try #require(transcriptScrollView(in: controller.view))
                _ = try await original.evaluateJavaScript("document.getElementById('input').value='Retained form';window.retainedToken='retained';")
                scroll.scroll?("top")
                try await wait {
                    !original.convert(original.bounds, to: viewport).intersects(viewport.bounds)
                        && scroll.instance.admissionDemand?.occurrenceVisible == false
                }
                #expect(scroll.instance.admissionDemand?.active == true)
                #expect(webViews(in: controller.view).first === original)
                #expect(try await original.evaluateJavaScript("document.getElementById('input').value") as? String == "Retained form")
                #expect(try await original.evaluateJavaScript("window.retainedToken") as? String == "retained")

                scroll.width = 670
                scroll.scroll?("visual")
                try await wait { original.bounds.width == 670 && original.convert(original.bounds, to: viewport).intersects(viewport.bounds) }
                #expect(webViews(in: controller.view).first === original)
                #expect(try await original.evaluateJavaScript("document.getElementById('input').value") as? String == "Retained form")
                #expect(try await original.evaluateJavaScript("window.retainedToken") as? String == "retained")
                scroll.visibility.setVisibleRowIDs([])
                try await wait { webViews(in: controller.view).isEmpty }
            } catch {
                source.preparation.cancelDemand()
                fixture.window.close()
                await store.retire()
                throw error
            }
            source.preparation.cancelDemand()
            fixture.window.close()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inlineSuspensionPreservesRowHeight() async throws {
        try await withFixture { fixture in
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let sourceFile = fixture.directory.appending(path: "source.html")
            try await Self.write(html, to: sourceFile)
            _ = try await documents.store(hostID: hostID, reference: fixture.reference, source: sourceFile)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let visibility = TranscriptVisibility()
            visibility.setVisibleRowIDs(["visual"])
            let geometry = InlineGeometryFixture()
            let controller = UIHostingController(rootView:
                ScrollView {
                    HTMLVisualInline(url: fixture.url, title: "Height continuity")
                        .frame(width: 320)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { geometry.height = $0 }
                }
                    .environment(\.transcriptRowVisibility, TranscriptRowVisibility(rowID: "visual", visibility: visibility))
                    .environment(\.htmlVisualSource, source)
                    .environment(\.htmlVisualTheme, theme)
                    .environment(\.scenePhase, .active)
                    .environment(AppThemeStore()))
            fixture.window.show(controller)
            do {
                let key = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 320, theme: theme)
                try await wait {
                    webViews(in: controller.view).first?.bounds.height == 80 && geometry.height == 80
                        && fixture.renderer.snapshot(for: key).image != nil
                }
                let liveHeight = geometry.height
                #expect(liveHeight == 80)
                visibility.setVisibleRowIDs([])
                try await wait { webViews(in: controller.view).isEmpty }
                #expect(abs(geometry.height - liveHeight) < 1)
                visibility.setVisibleRowIDs(["visual"])
                try await wait { webViews(in: controller.view).first?.bounds.height == 80 }
                #expect(abs(geometry.height - liveHeight) < 1)
            } catch {
                visibility.setVisibleRowIDs([])
                fixture.window.close()
                await store.retire()
                throw error
            }
            visibility.setVisibleRowIDs([])
            fixture.window.close()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func identicalOccurrencesKeepTheirOwnCapturedPixelsWhenOtherOccurrenceCapturesLast() async throws {
        try await withFixture { fixture in
            let first = fixture.start()
            let second = fixture.start()
            fixture.renderer.setCaptureAllowed(first, true)
            fixture.renderer.setCaptureAllowed(second, true)
            try await wait { first.capturedImage != nil && second.capturedImage != nil }
            let firstPage = try #require(first.page)
            let secondPage = try #require(second.page)
            let firstInitialID = first.capturedImage?.id
            _ = try await firstPage.callJavaScript("""
                const content=document.getElementById('content');
                content.style.backgroundColor='rgb(255,0,0)';content.textContent='First occurrence';
                document.dispatchEvent(new Event('change',{bubbles:true}));
                """, contentWorld: .page)
            try await wait { first.capturedImage != nil && first.capturedImage?.id != firstInitialID }
            let redCapture = try #require(first.capturedImage)
            let redPixel = try await Self.centerPixel(redCapture.data)
            #expect(redPixel.red > 240 && redPixel.green < 15 && redPixel.blue < 15)

            let secondInitialID = second.capturedImage?.id
            _ = try await secondPage.callJavaScript("""
                const content=document.getElementById('content');
                content.style.backgroundColor='rgb(0,0,255)';content.textContent='Second occurrence';
                document.dispatchEvent(new Event('change',{bubbles:true}));
                """, contentWorld: .page)
            try await wait { second.capturedImage != nil && second.capturedImage?.id != secondInitialID }
            let blueCapture = try #require(second.capturedImage)
            let bluePixel = try await Self.centerPixel(blueCapture.data)
            #expect(bluePixel.red < 15 && bluePixel.green < 15 && bluePixel.blue > 240)
            #expect(first.capturedImage?.id == redCapture.id)
            #expect(first.capturedImage?.data == redCapture.data)
            #expect(redCapture.data != blueCapture.data)
            #expect(first.snapshot === second.snapshot)
            #expect(first.snapshot?.image == blueCapture.data)
            let firstAfterSecond = try await Self.centerPixel(try #require(first.capturedImage?.data))
            #expect(firstAfterSecond.red > 240 && firstAfterSecond.blue < 15)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func widthChangeCapturesKeepTheirKeysPixelsAndDocumentStateIsolated() async throws {
        try await withFixture { fixture in
            let first = fixture.start()
            let second = fixture.start()
            try await wait { first.status == .live && second.status == .live && first.measured && second.measured }
            let controller = try #require(fixture.controller)
            let firstPage = try #require(first.page)
            let secondPage = try #require(second.page)
            _ = try await firstPage.callJavaScript("""
                const style=document.createElement('style');
                style.textContent='#content{background:rgb(255,0,0)}@media(min-width:480px){#content{background:rgb(0,0,255)}}';
                document.head.appendChild(style);document.getElementById('content').textContent='';
                window.resizeToken='retained';window.resizeLoads=(window.resizeLoads||0)+1;
                document.dispatchEvent(new Event('change',{bubbles:true}));
                """, contentWorld: .page)
            _ = try await secondPage.callJavaScript("""
                const content=document.getElementById('content');content.textContent='';
                content.style.backgroundColor='rgb(0,255,0)';
                document.dispatchEvent(new Event('change',{bubbles:true}));
                """, contentWorld: .page)
            fixture.renderer.setCaptureAllowed(first, true)
            fixture.renderer.setCaptureAllowed(second, true)
            try await wait { first.capturedImage != nil && second.capturedImage != nil }
            let narrowKey = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 320, theme: theme)
            let wideKey = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 640, theme: theme)
            let narrowCapture = try #require(first.capturedImage)
            let secondCapture = try #require(second.capturedImage)
            #expect(narrowCapture.key == narrowKey)
            #expect(secondCapture.key == narrowKey)
            let narrowPixel = try await Self.centerPixel(narrowCapture.data)
            let secondPixel = try await Self.centerPixel(secondCapture.data)
            #expect(narrowPixel.red > 240 && narrowPixel.green < 15 && narrowPixel.blue < 15)
            #expect(secondPixel.red < 15 && secondPixel.green > 240 && secondPixel.blue < 15)

            fixture.renderer.setCaptureAllowed(first, false)
            fixture.renderer.beginResize(first)
            fixture.widths[ObjectIdentifier(first)] = 640
            try await wait { webViews(in: controller.view).contains { abs($0.bounds.width - 640) < 1 } }
            fixture.renderer.finishResize(first, key: wideKey)
            #expect(first.capturedImage == nil)
            fixture.renderer.setCaptureAllowed(first, true)
            try await wait { first.capturedImage?.key == wideKey }
            let wideCapture = try #require(first.capturedImage)
            let widePixel = try await Self.centerPixel(wideCapture.data)
            #expect(widePixel.red < 15 && widePixel.green < 15 && widePixel.blue > 240)
            #expect(first.page === firstPage)
            #expect(second.page === secondPage)
            #expect(second.capturedImage?.id == secondCapture.id)
            #expect(second.capturedImage?.data == secondCapture.data)

            fixture.renderer.setCaptureAllowed(first, false)
            fixture.renderer.beginResize(first)
            fixture.widths[ObjectIdentifier(first)] = 320
            try await wait { webViews(in: controller.view).allSatisfy { abs($0.bounds.width - 320) < 1 } }
            fixture.renderer.finishResize(first, key: narrowKey)
            #expect(first.capturedImage == nil)
            fixture.renderer.setCaptureAllowed(first, true)
            try await wait { first.capturedImage?.key == narrowKey }
            let returnedCapture = try #require(first.capturedImage)
            let returnedPixel = try await Self.centerPixel(returnedCapture.data)
            #expect(returnedPixel.red > 240 && returnedPixel.green < 15 && returnedPixel.blue < 15)
            #expect(returnedCapture.id != narrowCapture.id && returnedCapture.id != wideCapture.id)
            #expect(first.page === firstPage)
            #expect(try await firstPage.callJavaScript("return window.resizeToken;", contentWorld: .page) as? String == "retained")
            #expect(try await firstPage.callJavaScript("return window.resizeLoads;", contentWorld: .page) as? Int == 1)
            #expect(second.capturedImage?.key == narrowKey)
            #expect(second.capturedImage?.data == secondCapture.data)
            let retainedNarrowPixel = try await Self.centerPixel(narrowCapture.data)
            let retainedWidePixel = try await Self.centerPixel(wideCapture.data)
            #expect(retainedNarrowPixel.red > 240 && retainedNarrowPixel.blue < 15)
            #expect(retainedWidePixel.red < 15 && retainedWidePixel.blue > 240)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inlineResizeDuringMotionKeepsNativeContentUntilMatchingCaptureIsPrepared() async throws {
        try await withFixture { fixture in
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let sourceFile = fixture.directory.appending(path: "resize.html")
            try await Self.write(html, to: sourceFile)
            _ = try await documents.store(hostID: hostID, reference: fixture.reference, source: sourceFile)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let motion = InlineMotionFixture()
            motion.visibility.setVisibleRowIDs(["first"])
            let controller = UIHostingController(rootView: InlineMotionView(fixture: motion, url: fixture.url)
                .environment(\.htmlVisualSource, source)
                .environment(\.htmlVisualTheme, theme)
                .environment(\.htmlVisualCaptureAllowed, true)
                .environment(\.scenePhase, .active)
                .environment(AppThemeStore()))
            fixture.window.show(controller)
            do {
                let narrowKey = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 320, theme: theme)
                let wideKey = HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 640, theme: theme)
                try await wait { webViews(in: controller.view).count == 1 && fixture.renderer.snapshot(for: narrowKey).image != nil }
                let original = try #require(webViews(in: controller.view).first)
                _ = try await original.evaluateJavaScript("window.resizeToken='retained';")
                motion.visibility.setScrollPhase(.decelerating)
                try await wait { motion.observedMoving == true && effectiveOpacity(of: original) == 0 }

                motion.width = 640
                try await wait { abs(original.bounds.width - 640) < 1 }
                #expect(effectiveOpacity(of: original) > 0.99)
                #expect(original.window != nil)
                #expect(webViews(in: controller.view).first === original)
                #expect(fixture.renderer.snapshot(for: wideKey).image == nil)
                _ = try await original.callAsyncJavaScript("await new Promise(resolve=>setTimeout(resolve,200)); return true;", in: nil, contentWorld: .page)
                #expect(effectiveOpacity(of: original) > 0.99)
                #expect(fixture.renderer.snapshot(for: wideKey).image == nil)
                #expect(try await original.evaluateJavaScript("window.resizeToken") as? String == "retained")

                motion.visibility.setScrollPhase(.idle)
                try await wait { motion.observedMoving == false && fixture.renderer.snapshot(for: wideKey).image != nil }
                motion.visibility.setScrollPhase(.decelerating)
                try await wait { motion.observedMoving == true && effectiveOpacity(of: original) == 0 }
                #expect(abs(original.bounds.width - 640) < 1)
                #expect(webViews(in: controller.view).first === original)
                motion.width = 320
                try await wait { abs(original.bounds.width - 320) < 1 }
                #expect(effectiveOpacity(of: original) > 0.99)
                #expect(try await original.evaluateJavaScript("window.resizeToken") as? String == "retained")
            } catch {
                motion.visibility.setVisibleRowIDs([])
                fixture.window.close()
                await store.retire()
                throw error
            }
            motion.visibility.setVisibleRowIDs([])
            try await wait { webViews(in: controller.view).isEmpty }
            fixture.window.close()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func instantRequestInCompactTranscriptAdmitsAndPreservesLiveVisualWithoutScrollAnimation(published: Bool) async throws {
        try await withFixture { fixture in
            let hostID = UUID()
            let documents = HTMLVisualDocumentCache(directory: fixture.directory.appending(path: "documents"),
                writer: HTMLVisualDocumentFileWriter())
            let sourceFile = fixture.directory.appending(path: "compact.html")
            try await Self.write(html, to: sourceFile)
            _ = try await documents.store(hostID: hostID, reference: fixture.reference, source: sourceFile)
            let store = HTMLVisualDocumentStore(hostID: hostID, access: RendererCacheOnlyAccess(), cache: documents)
            let source = HTMLVisualSource(hostID: hostID, documents: store, renderer: fixture.renderer,
                preparation: HTMLVisualPreparation(renderer: fixture.renderer))
            let message = ChatMessage(role: .codex, text: "![Compact visual](\(fixture.url.absoluteString))")
            let items = published
                ? [ChatStreamItem.publishedVisual(PublishedVisual(itemID: "publication",
                    publication: HTMLVisualPublication(reference: fixture.reference, title: "Compact visual")))]
                : [ChatStreamItem.message(message)]
            let conversationID = UUID()
            let snapshot = ConversationSnapshot(conversationID: conversationID, ownerID: conversationID,
                threadID: "compact-visual", revision: 1, messages: published ? [] : [message], timelines: [], items: items,
                lastTurnCompletedAt: nil, presentationRows: TranscriptPresentationRows(rowIDs: Set(items.map(\.id))))
            let transcript = CompactVisualTranscriptFixture(snapshot: snapshot)
            await transcript.renderedMessages.prepare(snapshot.messages)
            let controller = UIHostingController(rootView: CompactVisualTranscriptView(fixture: transcript)
                .environment(\.htmlVisualSource, source)
                .environment(\.htmlVisualTheme, theme)
                .environment(\.scenePhase, .active)
                .environment(AppThemeStore()))
            fixture.window.show(controller)
            do {
                withAnimation(.smooth(duration: 0.2)) { transcript.showsContent = true }
                try await wait { webViews(in: controller.view).count == 1 && webViews(in: controller.view).first?.bounds.height == 80 }
                let original = try #require(webViews(in: controller.view).first)
                let scroll = try #require(transcriptScrollView(in: controller.view))
                let key = HTMLVisualLayoutKey(digest: fixture.reference.digest,
                    width: Int(original.bounds.width.rounded()), theme: theme)
                try await wait { fixture.renderer.snapshot(for: key).image != nil && effectiveOpacity(of: original) > 0.99 }
                #expect(scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom <= scroll.bounds.height + 1)
                _ = try await original.evaluateJavaScript("window.instantRequestToken='retained';")
                let offset = scroll.contentOffset
                withAnimation(.smooth(duration: 0.2)) {
                    transcript.request = TranscriptRowRequest(rowID: items[0].id, token: 2, anchor: .top, motion: .instant)
                }
                _ = try await original.callAsyncJavaScript("await new Promise(resolve=>setTimeout(resolve,350)); return true;", in: nil, contentWorld: .page)
                #expect(webViews(in: controller.view).first === original)
                #expect(original.window != nil)
                #expect(original.bounds.height == 80)
                #expect(effectiveOpacity(of: original) > 0.99)
                #expect(try await original.evaluateJavaScript("window.instantRequestToken") as? String == "retained")
                #expect(!scroll.isDecelerating && !scroll.isDragging && !scroll.isTracking)
                #expect(scroll.layer.animationKeys()?.isEmpty ?? true)
                #expect(abs(scroll.contentOffset.y - offset.y) < 1)
                transcript.readingPosition.capture(scope: transcript.readingScope)
                #expect(!transcript.readingPosition.isFollowingLatest)
                #expect(transcript.readingPosition.anchor?.rowID == items[0].id)
            } catch {
                fixture.window.close()
                transcript.renderedMessages.retire()
                await store.retire()
                throw error
            }
            fixture.window.close()
            transcript.renderedMessages.retire()
            await store.retire()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func expansionPinSurvivesCancellationAndAdmissionRecreation() async throws {
        try await withFixture { fixture in
            let expanded = HTMLVisualInstance(surface: .expanded)
            fixture.start(expanded)
            try await wait { expanded.status == .live }
            await fixture.stop(expanded)
            #expect(expanded.pinned)
            #expect(expanded.page == nil)
            fixture.start(expanded)
            try await wait { expanded.status == .live }
            let expandedPage = try #require(expanded.page)
            let second = fixture.start()
            let third = fixture.start()
            try await wait { second.status == .live && third.status == .live }
            let selected = HTMLVisualInstance(surface: .inline)
            fixture.renderer.promote(selected)
            fixture.start(selected)
            try await wait { selected.status == .live }
            #expect(expanded.page === expandedPage)
            #expect(expanded.status == .live)
            #expect(expanded.pinned)
            #expect(fixture.pins[ObjectIdentifier(expanded)]?.last == true)
            #expect(second.status == .suspended)
            #expect(third.status == .live)
            #expect(fixture.instances.filter { $0.page != nil }.count == 3)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func expansionRunsItsOwnScrollingPageWithoutChangingInlineHeight() async throws {
        try await withFixture { fixture in
            let inline = fixture.start()
            try await wait { inline.status == .live && inline.measured }
            let inlineHeight = inline.height
            let key = try #require(inline.key)
            #expect(fixture.renderer.height(for: key) == inlineHeight)
            let expansion = HTMLVisualInstance(surface: .expanded)
            fixture.start(expansion)
            try await wait { expansion.status == .live && expansion.measured }
            let inlinePage = try #require(inline.page)
            let expandedPage = try #require(expansion.page)
            #expect(inlinePage !== expandedPage)
            _ = try await expandedPage.callJavaScript("document.getElementById('content').style.height='240px';",
                contentWorld: .page)
            try await wait { expansion.height >= 240 }
            #expect(fixture.renderer.height(for: key) == inlineHeight)
            #expect(inline.height == inlineHeight)
            let overflow = "return document.documentElement.style.getPropertyValue('overflow');"
            #expect(try await expandedPage.callJavaScript(overflow, contentWorld: .page) as? String == "auto")
            #expect(try await inlinePage.callJavaScript(overflow, contentWorld: .page) as? String == "clip")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func selectedWaitingRequestWinsReleasedSlotWhenEveryAdmissionIsPinned(beforeRequest: Bool) async throws {
        try await withFixture { fixture in
            let admitted = (0..<3).map { _ in HTMLVisualInstance(surface: .expanded) }
            for instance in admitted { fixture.startHoldingDocument(instance) }
            try await wait { admitted.allSatisfy { $0.status == .loading } }
            let automatic = fixture.start()
            try await wait { automatic.waiting }
            let selected = HTMLVisualInstance(surface: .inline)
            if beforeRequest { fixture.renderer.promote(selected) }
            fixture.start(selected)
            try await wait { selected.waiting }
            if !beforeRequest { fixture.renderer.promote(selected) }
            #expect(admitted.allSatisfy { $0.status == .loading && $0.pinned })
            #expect(selected.waiting)
            await fixture.stop(admitted[2])
            try await wait { selected.status == .live }
            #expect(automatic.waiting)
            #expect(admitted[0].status == .loading && admitted[1].status == .loading)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func expandedReadmissionUsesSelectedSlotUnderEnergyConservation() async throws {
        try await withFixture { fixture in
            fixture.renderer.setEnergyPolicy(AppEnergyPolicy(isLowPowerModeEnabled: true, thermalState: .nominal))
            let expanded = HTMLVisualInstance(surface: .expanded)
            fixture.start(expanded)
            try await wait { expanded.status == .live }
            await fixture.stop(expanded)
            let automatic = fixture.start()
            try await wait { automatic.status == .live }
            fixture.start(expanded)
            try await wait { expanded.status == .live }
            #expect(expanded.pinned)
            #expect(automatic.status == .live)
            #expect(fixture.instances.filter { $0.page != nil }.count == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func selectionBeforeRequestReplacesAnUnpinnedPageWithoutSecondPromotion() async throws {
        try await withFixture { fixture in
            let live = (0..<3).map { _ in fixture.start() }
            try await wait { live.allSatisfy { $0.status == .live } }
            let displaced = try #require(live[0].activity)
            let selected = HTMLVisualInstance(surface: .inline)
            fixture.renderer.promote(selected)
            fixture.start(selected)
            try await wait { selected.status == .live }
            #expect(live[0].status == .suspended)
            #expect(displaced.releaseReason == .selectedEviction)
            #expect(live[1].status == .live && live[2].status == .live)
            #expect(fixture.instances.filter { $0.page != nil }.count == 3)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func releasedPageBridgeCannotChangeReplacementGeometryOrPin() async throws {
        try await withFixture { fixture in
            let instance = fixture.start()
            try await wait { instance.status == .live && instance.height == 80 }
            let oldPage = try #require(instance.page)
            await fixture.stop(instance)
            fixture.start(instance)
            try await wait { instance.status == .live && instance.height == 80 }
            let replacement = try #require(instance.page)
            #expect(replacement !== oldPage)
            let pinEvents = fixture.pins[ObjectIdentifier(instance)]?.count
            #expect(try await oldPage.callJavaScript("return typeof window.webkit?.messageHandlers?.rcVisual === 'undefined';",
                contentWorld: .defaultClient) as? Bool == true)
            _ = try await oldPage.callJavaScript("""
                document.getElementById('content').style.height='420px';
                const range=document.createRange();range.selectNodeContents(document.getElementById('content'));
                document.getSelection().removeAllRanges();document.getSelection().addRange(range);
                return new Promise(resolve=>setTimeout(()=>resolve(true),100));
                """, contentWorld: .defaultClient)
            #expect(instance.height == 80)
            #expect(!instance.pinned)
            #expect(fixture.pins[ObjectIdentifier(instance)]?.count == pinEvents)
            _ = try await replacement.callJavaScript("""
                document.getElementById('content').style.height='210px';
                globalThis.rcVisualMeasure(true);
                const range=document.createRange();range.selectNodeContents(document.getElementById('content'));
                document.getSelection().addRange(range);
                """, contentWorld: .defaultClient)
            try await wait { instance.height == 210 && instance.interacting }
            #expect(instance.page === replacement)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func snapshotExportWaitsForIdlePermission() async throws {
        try await withFixture { fixture in
            let instance = fixture.start()
            try await wait { instance.status == .live && instance.measured }
            let activity = try #require(instance.activity)
            #expect(activity.kind == .automatic)
            #expect(activity.layoutEvents > 0)
            #expect(activity.capturesStarted == 0)
            #expect(instance.capture == nil && instance.needsSnapshot)
            #expect(instance.snapshot?.image == nil)
            fixture.renderer.setCaptureAllowed(instance, true)
            try await wait { instance.snapshot?.image != nil }
            #expect(activity.capturesStarted >= activity.capturesCompleted)
            #expect(activity.capturesCompleted > 0)
            #expect(activity.captureDuration > .zero)
            fixture.renderer.setCaptureAllowed(instance, false)
            let revision = instance.snapshot?.revision
            let page = try #require(instance.page)
            _ = try await page.callJavaScript("document.getElementById('content').style.height='260px';globalThis.rcVisualMeasure(true);",
                contentWorld: .defaultClient)
            try await wait { instance.height == 260 }
            #expect(instance.capture == nil && instance.needsSnapshot)
            #expect(instance.snapshot?.revision == revision)
            await fixture.stop(instance)
            #expect(instance.activity == nil)
            #expect(activity.releaseReason == .cancelled)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedThemeUpdateReleasesThePageAndAdmission() async throws {
        try await withFixture { fixture in
            let instance = fixture.start()
            try await wait { instance.status == .live }
            let page = try #require(instance.page)
            _ = try await page.callJavaScript("document.documentElement.remove();", contentWorld: .page)
            fixture.renderer.update(instance,
                key: HTMLVisualLayoutKey(digest: fixture.reference.digest, width: 321, theme: theme))
            try await wait { instance.failure != nil && instance.page == nil }
            let replacements = (0..<3).map { _ in fixture.start() }
            try await wait { replacements.allSatisfy { $0.status == .live } }
            #expect(fixture.instances.filter { $0.page != nil }.count == 3)
        }
    }

    private func withFixture(_ operation: (RendererLifecycleFixture) async throws -> Void) async throws {
        let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = try #require(URL(string: "rc-visual:" + digest))
        let reference = try #require(HTMLVisualReference(url: url))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let fixture = RendererLifecycleFixture(directory: directory, scene: scene, reference: reference,
            url: url, key: HTMLVisualLayoutKey(digest: digest, width: 320, theme: theme), html: html,
            webContent: Self.webContent)
        await fixture.renderer.load()
        do {
            try await operation(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        if let page = view as? WKWebView { return [page] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private func transcriptScrollView(in view: UIView) -> UIScrollView? {
        if view is WKWebView { return nil }
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = transcriptScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func effectiveOpacity(of view: UIView) -> Float {
        var opacity: Float = 1
        var layer: CALayer? = view.layer
        while let current = layer {
            if current.isHidden { return 0 }
            opacity *= current.opacity
            layer = current.superlayer
        }
        return opacity
    }

    private struct Pixel: Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }


    @concurrent
    nonisolated private static func centerPixel(_ data: Data) async throws -> Pixel {
        let budget = HTMLVisualRasterBudget(capacity: HTMLVisualRasterBudget.maximumPixels,
            imagePixels: HTMLVisualRasterBudget.maximumImagePixels)
        let image = try #require(await budget.rasterize(data, displayScale: 1, minimumScale: 1)).image
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    @concurrent
    nonisolated private static func remove(_ directory: URL) async throws {
        try FileManager.default.removeItem(at: directory)
    }

    @concurrent
    nonisolated private static func write(_ html: String, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(html.utf8).write(to: url)
    }
}

@MainActor
@Observable
private final class RendererLifecycleFixture {
    let directory: URL
    let window: HostedWindow
    let renderer: HTMLVisualRenderer
    let reference: HTMLVisualReference
    let url: URL
    @ObservationIgnored private(set) weak var controller: UIViewController?
    private let key: HTMLVisualLayoutKey
    private let html: String
    private let cache: HTMLVisualPresentationCache
    var instances: [HTMLVisualInstance] = []
    var widths: [ObjectIdentifier: CGFloat] = [:]
    @ObservationIgnored var pins: [ObjectIdentifier: [Bool]] = [:]
    @ObservationIgnored private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(directory: URL, scene: UIWindowScene, reference: HTMLVisualReference, url: URL,
         key: HTMLVisualLayoutKey, html: String, webContent: HTMLVisualWebContent) {
        self.directory = directory
        window = HostedWindow(scene: scene)
        cache = HTMLVisualPresentationCache(directory: directory.appending(path: "presentations"), clock: ContinuousClock())
        renderer = HTMLVisualRenderer(cache: cache, webContent: webContent)
        self.reference = reference
        self.url = url
        self.key = key
        self.html = html
        let controller = UIHostingController(rootView: RendererLifecycleView(fixture: self))
        self.controller = controller
        window.show(controller)
    }

    @discardableResult
    func start() -> HTMLVisualInstance {
        let instance = HTMLVisualInstance(surface: .inline)
        start(instance)
        return instance
    }

    func start(_ instance: HTMLVisualInstance) {
        start(instance, document: { self.html })
    }

    func startHoldingDocument(_ instance: HTMLVisualInstance) {
        start(instance, document: {
            try await Task.sleep(for: .seconds(60))
            return self.html
        })
    }

    private func start(_ instance: HTMLVisualInstance,
                       document: @escaping @MainActor () async throws -> String) {
        if !instances.contains(where: { $0 === instance }) { instances.append(instance) }
        let identity = ObjectIdentifier(instance)
        tasks[identity] = Task { [renderer, reference, key, weak self] in
            await renderer.run(instance, reference: reference, key: key, document: document,
                open: { _ in Issue.record("Renderer fixture must not open links") },
                onPinChange: { [weak self] active in self?.pins[identity, default: []].append(active) })
        }
    }

    func stop(_ instance: HTMLVisualInstance) async {
        let task = tasks.removeValue(forKey: ObjectIdentifier(instance))
        task?.cancel()
        await task?.value
    }

    func close() async throws {
        window.close()
        let running = Array(tasks.values)
        tasks.removeAll()
        for task in running { task.cancel() }
        for task in running { await task.value }
        try await renderer.flush()
        try await cache.retire()
        try await Self.remove(directory)
    }

    @concurrent
    nonisolated private static func remove(_ directory: URL) async throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

private struct RendererLifecycleView: View {
    let fixture: RendererLifecycleFixture

    var body: some View {
        VStack {
            ForEach(fixture.instances.indices, id: \.self) { index in
                let instance = fixture.instances[index]
                if let page = instance.page {
                    WebView(page).frame(width: fixture.widths[ObjectIdentifier(instance)] ?? 320, height: 100)
                }
            }
        }
    }
}

@MainActor
@Observable
private final class InlineGeometryFixture {
    var height: CGFloat = 0
}

@MainActor
@Observable
private final class InlineOccurrenceFixture {
    let visibility = TranscriptVisibility()
    let instance = HTMLVisualInstance(surface: .inline)
    var width: CGFloat = 320
    @ObservationIgnored var scroll: ((String) -> Void)?
}

private struct InlineOccurrenceView: View {
    let fixture: InlineOccurrenceFixture
    let url: URL

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1_200).id("top")
                    HTMLVisualInline(url: url, title: "Occurrence", instance: fixture.instance)
                        .environment(\.transcriptRowVisibility,
                            TranscriptRowVisibility(rowID: "same-message", visibility: fixture.visibility))
                        .id("visual")
                    Color.clear.frame(height: 1_200)
                }
                .frame(width: fixture.width)
            }
            .frame(width: fixture.width, height: 240)
            .onAppear { fixture.scroll = { proxy.scrollTo($0, anchor: .top) } }
            .onDisappear { fixture.scroll = nil }
        }
        .dynamicTypeSize(.accessibility3)
    }
}

@MainActor
@Observable
private final class InlineMotionFixture {
    let visibility = TranscriptVisibility()
    var showSecond = false
    var width: CGFloat = 320
    @ObservationIgnored var observedMoving: Bool?
    @ObservationIgnored var observedScrolling: Bool?
    @ObservationIgnored var secondAppeared = false
}

private struct InlineMotionView: View {
    let fixture: InlineMotionFixture
    let url: URL

    private var firstVisibility: TranscriptRowVisibility {
        TranscriptRowVisibility(rowID: "first", visibility: fixture.visibility)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HTMLVisualInline(url: url, title: "First")
                    .environment(\.transcriptRowVisibility, firstVisibility)
                if fixture.showSecond {
                    HTMLVisualInline(url: url, title: "Second")
                        .environment(\.transcriptRowVisibility,
                            TranscriptRowVisibility(rowID: "second", visibility: fixture.visibility))
                        .onAppear { fixture.secondAppeared = true }
                }
            }
            .frame(width: fixture.width)
        }
        .onChange(of: firstVisibility.isMoving, initial: true) { _, moving in fixture.observedMoving = moving }
        .onChange(of: firstVisibility.isScrolling, initial: true) { _, scrolling in fixture.observedScrolling = scrolling }
    }
}

@MainActor
@Observable
private final class CompactVisualTranscriptFixture {
    let snapshot: ConversationSnapshot
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let renderedMessages = RenderedMessageStore()
    var showsContent = false
    var request: TranscriptRowRequest

    init(snapshot: ConversationSnapshot) {
        self.snapshot = snapshot
        request = TranscriptRowRequest(rowID: snapshot.items[0].id, token: 1, anchor: .top, motion: .instant)
        rowPresentations.prepareSource(snapshot, readingPosition: readingPosition)
    }
}

private struct CompactVisualTranscriptView: View {
    let fixture: CompactVisualTranscriptFixture

    var body: some View {
        ChatTranscriptView(items: fixture.showsContent ? fixture.snapshot.items : [],
            readingPosition: fixture.readingPosition, rowPresentations: fixture.rowPresentations,
            readingScope: fixture.readingScope, retainedSurfaces: nil, renderedMessages: fixture.renderedMessages,
            forkableMessageIDs: [], scrollToRow: fixture.request, onFork: { _ in },
            queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() }, onBackgroundTap: {},
            historyEdgeStatus: [:], canPrefetchOlderHistory: false, canLoadHistory: true, onLoadHistory: { _ in nil }, onShowLatest: {},
            onFirstContent: {}, bottomBar: Optional<EmptyView>.none)
    }
}

private actor RendererHoldingAccess: HostFileAccess {
    private var reads: [HTMLVisualReference: (id: UUID, continuation: CheckedContinuation<HostFileLease, any Error>)] = [:]
    private var arrivals: [HTMLVisualReference: CheckedContinuation<Void, Never>] = [:]
    private(set) var cancelled: Set<HTMLVisualReference> = []

    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) throws -> HostFileLease { throw HostFileError.unavailable }
    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                reads[reference] = (id, $0)
                arrivals.removeValue(forKey: reference)?.resume()
            }
        } onCancel: {
            Task { await self.cancel(reference, id: id) }
        }
    }
    func waitForRead(_ reference: HTMLVisualReference) async {
        if reads[reference] == nil { await withCheckedContinuation { arrivals[reference] = $0 } }
    }
    private func cancel(_ reference: HTMLVisualReference, id: UUID) {
        guard reads[reference]?.id == id, let read = reads.removeValue(forKey: reference) else { return }
        cancelled.insert(reference)
        read.continuation.resume(throwing: CancellationError())
    }
    func cachedCopy(for reference: HostFileReference) -> HostFileLease? { nil }
    func release(_ lease: HostFileLease) {}
}

private actor RendererPageDeadline {
    private var pending: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var arrival: CheckedContinuation<Void, Never>?

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                pending = (id, $0)
                arrival?.resume()
                arrival = nil
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func waitUntilArmed() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func fire() {
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume()
    }
    private func cancel(_ id: UUID) {
        guard pending?.id == id else { return }
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private actor RendererCacheOnlyAccess: HostFileAccess {
    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) throws -> HostFileLease { throw HostFileError.unavailable }
    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) throws -> HostFileLease { throw HostFileError.unavailable }
    func cachedCopy(for reference: HostFileReference) -> HostFileLease? { nil }
    func release(_ lease: HostFileLease) {}
}
