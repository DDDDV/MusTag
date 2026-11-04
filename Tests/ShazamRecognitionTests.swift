import AVFoundation
import ShazamKit
import XCTest
@testable import MusTag

final class ShazamRecognitionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShazamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testStereoFileIsResampledIntoBoundedSignaturesWithoutChangingSource() async throws {
        let file = try makeAudio(duration: 22, sampleRate: 48_000, channels: 2)
        let before = try Data(contentsOf: file)
        let signatures = try await ShazamRecognitionService.signatures(url: file, minimumDuration: 3, maximumDuration: 6)
        XCTAssertEqual(signatures.count, 3, "Long files produce at most three bounded windows")
        for signature in signatures {
            XCTAssertGreaterThanOrEqual(signature.duration, 3)
            XCTAssertLessThanOrEqual(signature.duration, 6)
            XCTAssertFalse(signature.dataRepresentation.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testRecognitionRetriesUnmatchedSegmentsAndStopsAtFirstMatch() async throws {
        let file = try makeAudio(duration: 19)
        let calls = ShazamMatchCounter()
        let expected = ShazamRecognitionResult(id: "123", title: "Identified song", artist: "Artist")
        let results = try await ShazamRecognitionService.recognize(url: file, minimumDuration: 3, maximumDuration: 6) { _ in
            await calls.increment() == 2 ? [expected] : []
        }
        XCTAssertEqual(results, [expected])
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testNoMatchRemainsAnEmptyResultAfterAllSegments() async throws {
        let file = try makeAudio(duration: 19)
        let calls = ShazamMatchCounter()
        let results = try await ShazamRecognitionService.recognize(url: file, minimumDuration: 3, maximumDuration: 6) { _ in
            _ = await calls.increment()
            return []
        }
        XCTAssertTrue(results.isEmpty)
        let count = await calls.count
        XCTAssertEqual(count, 3)
    }

    func testShortAudioIsRejectedBeforeAnyNetworkMatch() async throws {
        let file = try makeAudio(duration: 1)
        let calls = ShazamMatchCounter()
        do {
            _ = try await ShazamRecognitionService.recognize(url: file, minimumDuration: 3, maximumDuration: 6) { _ in
                _ = await calls.increment()
                return []
            }
            XCTFail("An undersized signature must not be sent")
        } catch {
            XCTAssertTrue(error is MusTagError)
        }
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testCancelledRecognitionDoesNotReturnLateMatchOrStartAnotherSegment() async throws {
        let file = try makeAudio(duration: 19)
        let started = expectation(description: "Matching started")
        let calls = ShazamMatchCounter()
        let task = Task {
            try await ShazamRecognitionService.recognize(url: file, minimumDuration: 3, maximumDuration: 6) { _ in
                _ = await calls.increment()
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return [ShazamRecognitionResult(id: "late", title: "Late", artist: "Artist")]
            }
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled matches must not be applied") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSessionTimeoutDetachesDelegateAndDoesNotWaitForServer() async throws {
        let session = SilentShazamSession()
        let request = ShazamMatchRequest(session: session, timeout: 0.02)
        let start = Date()
        do {
            _ = try await request.result(for: SHSignatureGenerator().signature())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is MusTagError)
            XCTAssertTrue(error.localizedDescription.contains("ShazamKit"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(session.matchCalls, 1)
        XCTAssertNil(session.delegate)
    }

    @MainActor
    func testSessionCancellationDetachesDelegateBeforeTimeout() async throws {
        let session = SilentShazamSession()
        let request = ShazamMatchRequest(session: session, timeout: 30)
        let task = Task { try await request.result(for: SHSignatureGenerator().signature()) }
        for _ in 0..<100 where session.matchCalls == 0 { await Task.yield() }
        XCTAssertEqual(session.matchCalls, 1)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(session.delegate)
        // A callback already queued before cancellation must not resume the continuation again.
        request.session(session, didNotFindMatchFor: SHSignatureGenerator().signature(), error: nil)
        await Task.yield()
    }

    @MainActor
    func testNoMatchCallbackCleansUpSession() async throws {
        let session = SilentShazamSession()
        let request = ShazamMatchRequest(session: session, timeout: 30)
        let signature = SHSignatureGenerator().signature()
        let task = Task { try await request.result(for: signature) }
        for _ in 0..<100 where session.matchCalls == 0 { await Task.yield() }
        request.session(session, didNotFindMatchFor: signature, error: nil)
        let results = try await task.value
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(session.delegate)
    }

    func testMetadataPreservesSourceIDsAndLinksWithoutInventingMissingFields() {
        let media = SHMediaItem(properties: [
            .shazamID: " 123 ", .title: " Song ", .artist: " Artist ", .genres: ["Pop", " "],
            .ISRC: "USAAA0000001", .artworkURL: URL(string: "https://is1-ssl.mzstatic.com/artwork.jpg")!,
            .appleMusicURL: URL(string: "https://music.apple.com/us/album/song/123")!
        ])
        let missingID = SHMediaItem(properties: [.title: "Missing ID"])
        let missingTitle = SHMediaItem(properties: [.shazamID: "456", .title: "  "])
        let results = ShazamRecognitionService.results(from: [media, media, missingID, missingTitle])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "123")
        XCTAssertEqual(results.first?.title, "Song")
        XCTAssertEqual(results.first?.artist, "Artist")
        XCTAssertEqual(results.first?.genres, ["Pop"])
        XCTAssertEqual(results.first?.isrc, "USAAA0000001")
        XCTAssertEqual(results.first?.appleMusicURL?.host, "music.apple.com")
        XCTAssertEqual(results.first?.artworkURL?.host, "is1-ssl.mzstatic.com")
    }

    func testMetadataDropsUnsafeURLsAndKeepsMissingArtistEmpty() {
        let media = SHMediaItem(properties: [
            .shazamID: "123", .title: "Song", .artworkURL: URL(string: "file:///private/test.jpg")!,
            .appleMusicURL: URL(string: "https://user:secret@music.apple.com/123")!,
            .webURL: URL(string: "http://www.shazam.com/track/123")!,
            .videoURL: URL(string: "https://user:secret@example.com/video")!
        ])
        let result = ShazamRecognitionService.results(from: [media]).first
        XCTAssertEqual(result?.artist, "")
        XCTAssertNil(result?.artworkURL)
        XCTAssertNil(result?.appleMusicURL)
        XCTAssertNil(result?.webURL)
        XCTAssertNil(result?.videoURL)
        XCTAssertNil(result?.subtitle)
        XCTAssertNil(result?.appleMusicID)
        XCTAssertNil(result?.creationDate)
        XCTAssertNil(result?.explicitContent, "An absent rating must remain unknown rather than become clean")
        XCTAssertNil(result?.matchOffset)
        XCTAssertNil(result?.frequencySkew)
        XCTAssertNil(result?.predictedCurrentMatchOffset)
        XCTAssertNil(result?.confidence)
        XCTAssertEqual(result?.timeRanges, [])
        XCTAssertEqual(result?.frequencySkewRanges, [])
    }

    func testAllPublicMediaMetadataSurvivesExtractionAndPersistence() throws {
        let created = Date(timeIntervalSince1970: 1_730_000_000)
        let timeRanges: [Range<TimeInterval>] = [1..<8, 12..<19]
        let skewRanges: [Range<Float>] = [-0.05..<0.05]
        let media = SHMediaItem(properties: [
            .shazamID: "123", .title: "Song", .artist: "Artist", .subtitle: " Subtitle ",
            .genres: ["Pop", "Rock"], .ISRC: "USAAA0000001", .appleMusicID: " 456 ",
            .appleMusicURL: URL(string: "https://music.apple.com/us/song/456")!,
            .artworkURL: URL(string: "https://is1-ssl.mzstatic.com/artwork.jpg")!,
            .webURL: URL(string: "https://www.shazam.com/track/123")!,
            .videoURL: URL(string: "https://example.com/music-video")!,
            .explicitContent: true, .creationDate: created,
            .timeRanges: timeRanges, .frequencySkewRanges: skewRanges,
            .matchOffset: -0.5, .frequencySkew: Float(0.025)
        ])
        let result = try XCTUnwrap(ShazamRecognitionService.results(from: [media]).first)
        XCTAssertEqual(result.subtitle, "Subtitle")
        XCTAssertEqual(result.appleMusicID, "456")
        XCTAssertEqual(result.webURL, media.webURL)
        XCTAssertEqual(result.videoURL, media.videoURL)
        XCTAssertEqual(result.explicitContent, true)
        XCTAssertEqual(result.creationDate, created)
        XCTAssertEqual(result.mediaItemID, media.id)
        XCTAssertEqual(result.timeRanges, timeRanges)
        XCTAssertEqual(result.frequencySkewRanges, skewRanges)
        XCTAssertEqual(result.matchOffset, -0.5, "Negative offsets are valid when a query starts before the recognized recording")
        XCTAssertEqual(result.frequencySkew, 0.025)
        let persisted = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ShazamRecognitionResult.self, from: persisted), result)
    }

    func testPublicMatchPropertiesPreserveValuesAndConfidenceScale() throws {
        var properties: [SHMediaItemProperty: Any] = [
            .shazamID: "123", .title: "Song",
            .matchOffset: -0.5, .frequencySkew: Float(0.05)
        ]
        if #available(iOS 18.4, *) { properties[.confidence] = Float(0.92) }
        let media = SHMediaItem(properties: properties)
        let result = try XCTUnwrap(ShazamRecognitionService.results(from: [media]).first)
        XCTAssertEqual(result.matchOffset, -0.5)
        XCTAssertEqual(result.frequencySkew, 0.05)
        // A predicted playhead is available only on real SHMatchedMediaItem results.
        // SHMediaItem's property factory does not construct a synthetic match subclass.
        XCTAssertNil(result.predictedCurrentMatchOffset)
        if #available(iOS 18.4, *) { XCTAssertEqual(result.confidence, 0.92) }
        else { XCTAssertNil(result.confidence) }
        XCTAssertEqual(try JSONDecoder().decode(ShazamRecognitionResult.self,
                                               from: JSONEncoder().encode(result)), result)
    }

    func testNonfiniteMatchValuesAreDroppedSoResultsRemainPersistable() throws {
        var properties: [SHMediaItemProperty: Any] = [
            .shazamID: "123", .title: "Song", .explicitContent: false,
            .matchOffset: Double.infinity, .frequencySkew: Float.nan
        ]
        if #available(iOS 18.4, *) { properties[.confidence] = Float(1.1) }
        let result = try XCTUnwrap(ShazamRecognitionService.results(from: [SHMediaItem(properties: properties)]).first)
        XCTAssertEqual(result.explicitContent, false)
        XCTAssertNil(result.matchOffset)
        XCTAssertNil(result.frequencySkew)
        XCTAssertNil(result.confidence)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
    }

    func testServiceErrorIncludesDiagnosticCodeWithoutEchoingServerDetails() {
        let error = NSError(domain: SHErrorDomain, code: 202,
                            userInfo: [NSLocalizedDescriptionKey: "private token from service"])
        let mapped = ShazamRecognitionService.recognitionError(error)
        XCTAssertTrue(mapped.localizedDescription.contains("ShazamKit 202"))
        XCTAssertFalse(mapped.localizedDescription.contains("private token"))
        XCTAssertTrue(ShazamRecognitionService.recognitionError(URLError(.cancelled)) is CancellationError)
    }

    private func makeAudio(duration: TimeInterval, sampleRate: Double = 44_100,
                           channels: AVAudioChannelCount = 1) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let frames = Int(duration * sampleRate)
        var position = 0
        while position < frames {
            let count = min(4_096, frames - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(channels) {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for frame in 0..<count {
                    let time = Double(position + frame) / sampleRate
                    let phase = 2 * Double.pi * (220 * time + 17 * time * time)
                    samples[frame] = Float(0.3 * sin(phase) + 0.2 * sin(phase * 1.53)
                                          + 0.1 * sin(phase * 3.71 + Double(channel)))
                }
            }
            try file.write(from: buffer)
            position += count
        }
        return url
    }
}

private actor ShazamMatchCounter {
    var count = 0
    func increment() -> Int { count += 1; return count }
}

/// No call to super: the tests never send signatures to Apple's service.
private final class SilentShazamSession: SHSession {
    var matchCalls = 0
    override func match(_ signature: SHSignature) { matchCalls += 1 }
}
