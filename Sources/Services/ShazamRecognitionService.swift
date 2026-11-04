import AVFoundation
import Foundation
import ShazamKit

/// A value snapshot of public Shazam metadata. Keep service details alongside the
/// editable tags: an item's creation date, for example, is not a release date.
struct ShazamRecognitionResult: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var genres: [String] = []
    var isrc: String? = nil
    var artworkURL: URL? = nil
    var appleMusicURL: URL? = nil
    var subtitle: String? = nil
    var appleMusicID: String? = nil
    var webURL: URL? = nil
    var videoURL: URL? = nil
    var explicitContent: Bool? = nil
    var creationDate: Date? = nil
    var mediaItemID: UUID? = nil
    var timeRanges: [Range<TimeInterval>] = []
    var frequencySkewRanges: [Range<Float>] = []
    var matchOffset: TimeInterval? = nil
    var frequencySkew: Float? = nil
    // This is a snapshot at recognition time, not a continuously updated playhead.
    var predictedCurrentMatchOffset: TimeInterval? = nil
    var confidence: Float? = nil
}

/// Matches signatures generated from an already staged local file. Never uses the microphone.
enum ShazamRecognitionService {
    typealias Matcher = @Sendable (SHSignature) async throws -> [ShazamRecognitionResult]

    static func recognize(url: URL) async throws -> [ShazamRecognitionResult] {
        try Task.checkCancellation()
        let limits = await MainActor.run {
            let catalog = SHSession().catalog
            return (catalog.minimumQuerySignatureDuration, catalog.maximumQuerySignatureDuration)
        }
        return try await recognize(url: url, minimumDuration: limits.0, maximumDuration: limits.1) { signature in
            try await ShazamMatchRequest().result(for: signature)
        }
    }

    /// Injectable matching keeps tests offline while exercising real decoding and signature generation.
    static func recognize(url: URL, minimumDuration: TimeInterval, maximumDuration: TimeInterval,
                          matcher: Matcher) async throws -> [ShazamRecognitionResult] {
        let signatures = try await signatures(url: url, minimumDuration: minimumDuration,
                                               maximumDuration: maximumDuration)
        for signature in signatures {
            try Task.checkCancellation()
            let matches = try await matcher(signature)
            try Task.checkCancellation()
            if !matches.isEmpty { return matches }
        }
        return []
    }

    /// Decode at most three contiguous windows, each at most 12 seconds and within catalog limits.
    /// Audio stays in small PCM buffers; the returned signatures cannot reproduce the source audio.
    static func signatures(url: URL, minimumDuration: TimeInterval,
                           maximumDuration: TimeInterval) async throws -> [SHSignature] {
        let worker = Task.detached(priority: .userInitiated) { () throws -> [SHSignature] in
            try Task.checkCancellation()
            guard minimumDuration.isFinite, maximumDuration.isFinite,
                  minimumDuration > 0, maximumDuration >= minimumDuration else {
                throw MusTagError.message(L10n.text("ShazamKit returned invalid recognition limits.",
                                                   "ShazamKit 返回了无效的识别时长限制。"))
            }
            // A future catalog can require a longer minimum; never exceed its maximum.
            let window = max(minimumDuration, min(maximumDuration, 12))
            guard window <= 60 else {
                throw MusTagError.message(L10n.text("ShazamKit requires an unsupported recognition duration.",
                                                   "ShazamKit 要求的识别时长暂不受支持。"))
            }
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw MusTagError.message(L10n.text("ShazamKit could not decode this audio file.",
                                                   "ShazamKit 无法解码此音频文件。"))
            }
            let rate = file.processingFormat.sampleRate
            guard rate.isFinite, rate > 0, file.processingFormat.channelCount > 0,
                  file.length > 0, Double(file.length) / rate >= minimumDuration else {
                throw insufficientAudio()
            }
            let windowFrames = AVAudioFramePosition((window * rate).rounded(.down))
            var results: [SHSignature] = []
            for index in 0..<3 {
                try Task.checkCancellation()
                let start = AVAudioFramePosition(index) * windowFrames
                guard start < file.length else { break }
                let end = min(file.length, start + windowFrames)
                let duration = Double(end - start) / rate
                guard duration >= minimumDuration else { break }
                let signature = try signature(file: file, startFrame: start, endFrame: end)
                // Silent sections can produce a shorter signature than the decoded input.
                if signature.duration >= minimumDuration && signature.duration <= maximumDuration {
                    results.append(signature)
                }
            }
            guard !results.isEmpty else { throw insufficientAudio() }
            return results
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() })
    }

    private static func signature(file: AVAudioFile, startFrame: AVAudioFramePosition,
                                  endFrame: AVAudioFramePosition) throws -> SHSignature {
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            throw MusTagError.message(L10n.text("Cannot convert this audio for ShazamKit.",
                                               "无法将此音频转换为 ShazamKit 支持的格式。"))
        }
        file.framePosition = startFrame
        let generator = SHSignatureGenerator()
        let targetFrames = Int64((Double(endFrame - startFrame) * outputFormat.sampleRate
                                / inputFormat.sampleRate).rounded(.down))
        var producedFrames: Int64 = 0
        while producedFrames < targetFrames {
            try Task.checkCancellation()
            var readError: Error?
            var conversionError: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                if Task.isCancelled {
                    readError = CancellationError()
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let remaining = endFrame - file.framePosition
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let count = min(AVAudioFrameCount(min(remaining, 8_192)), requested)
                    try file.read(into: input, frameCount: count)
                    inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            try Task.checkCancellation()
            guard status != .error, conversionError == nil else {
                throw MusTagError.message(L10n.text("Audio conversion for ShazamKit failed.",
                                                   "转换 ShazamKit 音频时失败。"))
            }
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), targetFrames - producedFrames))
            if output.frameLength > 0 {
                try generator.append(output, at: nil)
                producedFrames += Int64(output.frameLength)
            }
            if status == .endOfStream || (status == .inputRanDry && output.frameLength == 0) { break }
        }
        return generator.signature()
    }

    static func results(from mediaItems: [SHMediaItem]) -> [ShazamRecognitionResult] {
        var seen: Set<String> = []
        return mediaItems.compactMap { item in
            guard let id = nonempty(item.shazamID), let title = nonempty(item.title),
                  seen.insert(id).inserted else { return nil }
            let matched = item as? SHMatchedMediaItem
            var confidence: Float?
            if #available(iOS 18.4, *) {
                let value = (item[.confidence] as? NSNumber)?.floatValue ?? matched?.confidence
                if let value, value.isFinite, (0...1).contains(value) { confidence = value }
            }
            let creationDate = item.creationDate.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
            return ShazamRecognitionResult(id: id, title: title, artist: nonempty(item.artist) ?? "",
                genres: item.genres.compactMap(nonempty), isrc: nonempty(item.isrc),
                artworkURL: secureURL(item.artworkURL), appleMusicURL: secureURL(item.appleMusicURL),
                subtitle: nonempty(item.subtitle), appleMusicID: nonempty(item.appleMusicID),
                webURL: secureURL(item.webURL), videoURL: secureURL(item.videoURL),
                explicitContent: (item[.explicitContent] as? NSNumber)?.boolValue,
                creationDate: creationDate, mediaItemID: item.id,
                timeRanges: item.timeRanges.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite },
                frequencySkewRanges: item.frequencySkewRanges.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite },
                matchOffset: finite((item[.matchOffset] as? NSNumber)?.doubleValue ?? matched?.matchOffset),
                frequencySkew: finite((item[.frequencySkew] as? NSNumber)?.floatValue ?? matched?.frequencySkew),
                predictedCurrentMatchOffset: finite(matched?.predictedCurrentMatchOffset), confidence: confidence)
        }
    }

    private static func finite<T: BinaryFloatingPoint>(_ value: T?) -> T? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func secureURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func insufficientAudio() -> MusTagError {
        .message(L10n.text("Not enough audible audio for ShazamKit. Try a longer file or edit the tags manually.",
                           "可识别的音频过短或为静音，请尝试更长的文件或手动编辑标签。"))
    }

    static func recognitionError(_ error: Error) -> Error {
        let nsError = error as NSError
        if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            return CancellationError()
        }
        let message: String
        if nsError.domain == SHErrorDomain && [100, 101, 200, 201].contains(nsError.code) {
            message = L10n.text("ShazamKit could not use this audio signature. Try another file or edit the tags manually.",
                                "ShazamKit 无法使用此音频签名，请尝试其他文件或手动编辑标签。")
        } else {
            message = L10n.text(
                "ShazamKit could not complete recognition. Check your connection. For a development build, enable ShazamKit for this App ID in your Apple Developer account and check signing.",
                "ShazamKit 无法完成识别，请检查网络。开发版本还需在 Apple 开发者账户中为此 App ID 启用 ShazamKit，并检查签名配置。")
        }
        // Show a diagnostic code, never an arbitrary server description that might contain request data.
        let domain = nsError.domain == SHErrorDomain ? "ShazamKit" : (nsError.domain == NSURLErrorDomain ? "URL" : "Service")
        return MusTagError.message("\(message) (\(domain) \(nsError.code))")
    }
}

/// SHSession has no cancel method. Detaching its delegate and releasing it lets cancellation
/// finish promptly even if the service never calls back; late callbacks cannot resume twice.
@MainActor
final class ShazamMatchRequest: NSObject, SHSessionDelegate {
    private var session: SHSession?
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<[ShazamRecognitionResult], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(session: SHSession = SHSession(), timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    func result(for signature: SHSignature) async throws -> [ShazamRecognitionResult] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !completed, self.continuation == nil, let session else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                session.delegate = self
                timeoutTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: .seconds(max(0.001, min(timeout, 120)))) }
                    catch { return }
                    self?.finish(.failure(MusTagError.message(L10n.text(
                        "ShazamKit recognition timed out. Check your connection and try again.",
                        "ShazamKit 识别超时，请检查网络后重试。"))))
                }
                session.match(signature)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        })
    }

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        let results = ShazamRecognitionService.results(from: match.mediaItems)
        Task { @MainActor [weak self] in self?.finish(.success(results)) }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        let result: Result<[ShazamRecognitionResult], Error> = error.map {
            .failure(ShazamRecognitionService.recognitionError($0))
        } ?? .success([])
        Task { @MainActor [weak self] in self?.finish(result) }
    }

    private func finish(_ result: Result<[ShazamRecognitionResult], Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        session?.delegate = nil
        session = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
