import AVFoundation
import Darwin
import Foundation
import VoCalCapture
import VoCalVoice
import Synchronization

// Port provenance: Serein apps/ios/SereinApp/Sources/VoiceCaptureSupport.swift,
// verbatim with Serein → VoCal module renames. Preserved unchanged on purpose:
// the filesystem session ledger (VoiceSessionStore: atomic tmp→rename snapshot
// persistence, fsync on file + directory, .completeUntilFirstUserAuthentication file
// protection), the CAF muxer constants (24kHz mono 16-bit LPCM — dogfooded, do not
// "improve"), and both recorder backends. No seams were cut in this file.

struct VoiceSessionBundle: Sendable {
    let bundleURL: URL
    let sessionURL: URL
    let audioURL: URL
    let quarantineURL: URL

    func relativePath(for url: URL) -> String {
        let prefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
        return url.path.replacingOccurrences(of: prefix, with: "")
    }
}

struct VoiceSessionStore {
    let appGroupRoot: URL
    let fileManager: FileManager

    init(appGroupRoot: URL, fileManager: FileManager = .default) {
        self.appGroupRoot = appGroupRoot
        self.fileManager = fileManager
    }

    func activeBundles() throws -> [VoiceSessionBundle] {
        let root = VoCalCapturePaths.voiceSessionsActiveRoot(appGroupRoot: appGroupRoot)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return makeBundle(url: url)
        }
    }

    func createActiveBundle(sessionID: String) throws -> VoiceSessionBundle {
        let root = VoCalCapturePaths.voiceSessionsActiveRoot(appGroupRoot: appGroupRoot)
        let bundleURL = root.appendingPathComponent(sessionID, isDirectory: true)
        let bundle = makeBundle(url: bundleURL)
        try fileManager.createDirectory(at: bundle.bundleURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle.quarantineURL, withIntermediateDirectories: true)
        return bundle
    }

    func bundle(sessionID: String) -> VoiceSessionBundle {
        let root = VoCalCapturePaths.voiceSessionsActiveRoot(appGroupRoot: appGroupRoot)
        return makeBundle(url: root.appendingPathComponent(sessionID, isDirectory: true))
    }

    func loadSession(from bundle: VoiceSessionBundle) throws -> VoiceSessionSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            return try CaptureDateCodec.parseInternetDate(raw)
        }
        let data = try Data(contentsOf: bundle.sessionURL)
        return try decoder.decode(VoiceSessionSnapshot.self, from: data)
    }

    func persist(session: VoiceSessionSnapshot, to bundle: VoiceSessionBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CaptureDateCodec.internetString(date))
        }
        let data = try encoder.encode(session)
        let tmpURL = bundle.sessionURL.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: tmpURL.path) {
            try fileManager.removeItem(at: tmpURL)
        }
        try data.write(to: tmpURL, options: .atomic)
        try syncFile(at: tmpURL)
        try setProtection(.completeUntilFirstUserAuthentication, for: tmpURL)
        if fileManager.fileExists(atPath: bundle.sessionURL.path) {
            try fileManager.removeItem(at: bundle.sessionURL)
        }
        try fileManager.moveItem(at: tmpURL, to: bundle.sessionURL)
        try syncDirectory(at: bundle.bundleURL)
        try setProtection(.completeUntilFirstUserAuthentication, for: bundle.sessionURL)
    }

    func removeBundle(_ bundle: VoiceSessionBundle) throws {
        if fileManager.fileExists(atPath: bundle.bundleURL.path) {
            try fileManager.removeItem(at: bundle.bundleURL)
        }
    }

    func moveToQuarantine(_ bundle: VoiceSessionBundle) throws -> VoiceSessionBundle {
        let root = VoCalCapturePaths.voiceSessionsQuarantineRoot(appGroupRoot: appGroupRoot)
        let base = bundle.bundleURL.lastPathComponent
        var destination = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.moveItem(at: bundle.bundleURL, to: destination)
        try syncDirectory(at: root)
        return makeBundle(url: destination)
    }

    func setProtection(_ protection: FileProtectionType, for url: URL) throws {
        try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    func fileSize(at url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber) ?? nil)?.int64Value ?? 0
    }

    private func makeBundle(url: URL) -> VoiceSessionBundle {
        VoiceSessionBundle(
            bundleURL: url,
            sessionURL: url.appendingPathComponent("session.json", isDirectory: false),
            audioURL: url.appendingPathComponent("voice.caf", isDirectory: false),
            quarantineURL: url.appendingPathComponent("quarantine", isDirectory: true)
        )
    }

    private func syncFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func syncDirectory(at url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

enum VoiceCAFMuxer {
    static let sampleRate: Double = 24_000
    static let channels: UInt32 = 1
    static let bitsPerChannel: UInt32 = 16
    static let bytesPerFrame: UInt32 = channels * (bitsPerChannel / 8)
    static let headerByteCount: Int64 = 68
    static let minimumCommittedDuration: TimeInterval = 1
    // CAF desc chunks use CAF-specific LPCM flags, not AudioStreamBasicDescription flags.
    // `0x2` is little-endian LPCM, which matches our AVAudioRecorder/AVAudioEngine payload bytes.
    static let formatFlags: UInt32 = 0x2
    static let audioFormat = CAFAudioFormat(
        sampleRate: sampleRate,
        formatID: kAudioFormatLinearPCM,
        formatFlags: formatFlags,
        bytesPerPacket: bytesPerFrame,
        framesPerPacket: 1,
        channelsPerFrame: channels,
        bitsPerChannel: bitsPerChannel
    )

    static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: Int(bitsPerChannel),
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    static func writeOpenSegmentHeader(to url: URL, audioFormat: CAFAudioFormat = audioFormat) throws {
        try fileData(audioFormat: audioFormat, openEnded: true, pcmPayload: Data()).write(to: url, options: .atomic)
    }

    static func appendPCMData(
        _ pcmPayload: Data,
        toOpenSegment url: URL,
        audioFormat: CAFAudioFormat = audioFormat
    ) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeOpenSegmentHeader(to: url, audioFormat: audioFormat)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: pcmPayload)
    }

    static func writeClosedSegment(
        _ pcmPayload: Data,
        to url: URL,
        audioFormat: CAFAudioFormat = audioFormat
    ) throws {
        try fileData(audioFormat: audioFormat, openEnded: false, pcmPayload: pcmPayload).write(to: url, options: .atomic)
    }

    static func prepareSingleFileForCommit(
        session: inout VoiceSessionSnapshot,
        bundle: VoiceSessionBundle,
        store: VoiceSessionStore,
        repairer: CAFRepairer
    ) throws -> URL {
        guard var audioFile = session.audioFile else {
            throw VoiceCaptureError.noRecoverableAudio
        }

        let fileURL = bundle.bundleURL.appendingPathComponent(audioFile.relpath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            audioFile.status = .quarantined
            audioFile.repairStatus = .failed
            session.audioFile = audioFile
            if audioFile.bytes > 0 {
                throw VoiceCaptureError.commitDeferred("audio_file_missing")
            }
            throw VoiceCaptureError.noRecoverableAudio
        }

        guard var analysis = repairer.analyze(fileURL: fileURL) else {
            audioFile.status = .quarantined
            audioFile.repairStatus = .failed
            session.audioFile = audioFile
            if audioFile.bytes > 0 {
                throw VoiceCaptureError.commitDeferred("audio_file_unreadable")
            }
            throw VoiceCaptureError.noRecoverableAudio
        }

        if analysis.status == .needsRepair {
            switch repairer.repair(analysis: analysis) {
            case .success:
                audioFile.repairStatus = .repaired
                guard let repaired = repairer.analyze(fileURL: fileURL) else {
                    audioFile.status = .quarantined
                    audioFile.repairStatus = .failed
                    session.audioFile = audioFile
                    throw VoiceCaptureError.commitDeferred("audio_file_repair_unreadable")
                }
                analysis = repaired
            case .failed, .notImplemented:
                audioFile.status = .quarantined
                audioFile.repairStatus = .failed
                session.audioFile = audioFile
                throw VoiceCaptureError.commitDeferred("audio_file_repair_failed")
            }
        } else {
            audioFile.repairStatus = .notNeeded
        }

        if analysis.status == .emptyData {
            audioFile.bytes = Int64(analysis.fileSize)
            session.audioFile = audioFile
            throw VoiceCaptureError.noRecoverableAudio
        }

        guard analysis.status == .valid,
              let desc = analysis.descChunk,
              desc.audioFormat.isCompatible(with: audioFormat),
              let dataChunk = analysis.dataChunk
        else {
            audioFile.status = .quarantined
            audioFile.repairStatus = .failed
            session.audioFile = audioFile
            throw VoiceCaptureError.commitDeferred("audio_file_invalid")
        }

        let payloadBytes = max(0, analysis.fileSize - Int64(dataChunk.dataOffset))
        audioFile.bytes = Int64(analysis.fileSize)
        audioFile.closedAt = audioFile.closedAt ?? Date()
        session.audioFile = audioFile
        guard payloadBytes > 0 else {
            throw VoiceCaptureError.noRecoverableAudio
        }
        guard payloadBytes >= minimumCommittedPayloadBytes else {
            throw VoiceCaptureError.captureTooShort
        }

        try store.setProtection(.completeUntilFirstUserAuthentication, for: fileURL)
        session.finalBlobRelpath = audioFile.relpath
        return fileURL
    }

    static func recordedDuration(forStoredBytes storedBytes: Int64) -> TimeInterval {
        let payloadBytes = max(0, storedBytes - headerByteCount)
        let frames = Double(payloadBytes) / Double(bytesPerFrame)
        return frames / sampleRate
    }

    static var minimumCommittedPayloadBytes: Int64 {
        Int64((minimumCommittedDuration * sampleRate * Double(bytesPerFrame)).rounded(.up))
    }

    private static func fileData(audioFormat: CAFAudioFormat, openEnded: Bool, pcmPayload: Data) throws -> Data {
        var data = Data()
        var magic = UInt32(0x63616666).bigEndian
        var version = UInt16(1).bigEndian
        var flags = UInt16(0).bigEndian
        data.append(Data(bytes: &magic, count: 4))
        data.append(Data(bytes: &version, count: 2))
        data.append(Data(bytes: &flags, count: 2))

        var descType = UInt32(0x64657363).bigEndian
        var descSize = Int64(32).bigEndian
        data.append(Data(bytes: &descType, count: 4))
        data.append(Data(bytes: &descSize, count: 8))

        var sampleRateBits = audioFormat.sampleRate.bitPattern.bigEndian
        var formatID = audioFormat.formatID.bigEndian
        var formatFlags = audioFormat.formatFlags.bigEndian
        var bytesPerPacket = audioFormat.bytesPerPacket.bigEndian
        var framesPerPacket = audioFormat.framesPerPacket.bigEndian
        var channelsPerFrame = audioFormat.channelsPerFrame.bigEndian
        var bitsPerChannel = audioFormat.bitsPerChannel.bigEndian
        data.append(Data(bytes: &sampleRateBits, count: 8))
        data.append(Data(bytes: &formatID, count: 4))
        data.append(Data(bytes: &formatFlags, count: 4))
        data.append(Data(bytes: &bytesPerPacket, count: 4))
        data.append(Data(bytes: &framesPerPacket, count: 4))
        data.append(Data(bytes: &channelsPerFrame, count: 4))
        data.append(Data(bytes: &bitsPerChannel, count: 4))

        var dataType = UInt32(0x64617461).bigEndian
        let declaredSize = openEnded ? Int64(-1) : Int64(4 + pcmPayload.count)
        var chunkSize = declaredSize.bigEndian
        var editCount = UInt32(0).bigEndian
        data.append(Data(bytes: &dataType, count: 4))
        data.append(Data(bytes: &chunkSize, count: 8))
        data.append(Data(bytes: &editCount, count: 4))
        data.append(pcmPayload)
        return data
    }
}

protocol VoiceRecorderSession: AnyObject {
    var fileURL: URL { get }
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    func record() -> Bool
    func stop()
}

protocol VoiceRecorderFactory: AnyObject {
    func makeRecorder(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws -> VoiceRecorderSession
}

final class AVAudioEngineRecorderFactory: VoiceRecorderFactory {
    func makeRecorder(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws -> VoiceRecorderSession {
        try AVAudioEngineRecorderSession(
            fileURL: fileURL,
            appendToExisting: appendToExisting,
            onUnexpectedStop: onUnexpectedStop,
            onConfigurationChange: onConfigurationChange,
            onStopFinished: onStopFinished
        )
    }
}

final class VoicePCMBufferConverter {
    private enum ConversionMode {
        case simple
        case streaming
    }

    let targetFormat: AVAudioFormat

    private let conversionMode: ConversionMode
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw VoiceCaptureError.recorderFailed("engine_converter_unavailable")
        }
        self.converter = converter
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount
        {
            conversionMode = .simple
        } else {
            conversionMode = .streaming
            converter.primeMethod = .none
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        if canWriteBufferDirectly(buffer) {
            return Self.pcmData(from: buffer)
        }

        let scaledCapacity = outputFrameCapacity(for: buffer)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: scaledCapacity) else {
            throw VoiceCaptureError.recorderFailed("engine_output_buffer_unavailable")
        }

        switch conversionMode {
        case .simple:
            return try simpleConvert(buffer, into: converted)
        case .streaming:
            return try streamingConvert(buffer, into: converted)
        }
    }

    private func outputFrameCapacity(for buffer: AVAudioPCMBuffer) -> AVAudioFrameCount {
        max(
            AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * (targetFormat.sampleRate / max(buffer.format.sampleRate, 1)))
            ) + 32,
            64
        )
    }

    private func simpleConvert(_ buffer: AVAudioPCMBuffer, into converted: AVAudioPCMBuffer) throws -> Data {
        let sourceSummary = describeFormat(sourceFormat)
        let bufferSummary = describeFormat(buffer.format)
        let targetSummary = describeFormat(targetFormat)
        do {
            try converter.convert(to: converted, from: buffer)
        } catch {
            let reason = "converter_simple_failed:source=\(sourceSummary):buffer=\(bufferSummary):target=\(targetSummary):\(error.localizedDescription)"
            throw VoiceCaptureError.recorderFailed(reason)
        }
        return Self.pcmData(from: converted)
    }

    private func streamingConvert(_ buffer: AVAudioPCMBuffer, into converted: AVAudioPCMBuffer) throws -> Data {
        var output = Data()
        let sourceSummary = describeFormat(sourceFormat)
        let bufferSummary = describeFormat(buffer.format)
        let targetSummary = describeFormat(targetFormat)
        let sourceConsumed = Mutex(false)
        let bufferAddress = Int(bitPattern: Unmanaged.passUnretained(buffer).toOpaque())

        var awaitingOutput = true
        while awaitingOutput {
            converted.frameLength = 0
            var conversionError: NSError?
            let status = withExtendedLifetime(buffer) {
                converter.convert(to: converted, error: &conversionError) { _, outStatus in
                    let shouldProvideBuffer = sourceConsumed.withLock { sourceConsumed -> Bool in
                        if sourceConsumed {
                            outStatus.pointee = .noDataNow
                            return false
                        }
                        sourceConsumed = true
                        outStatus.pointee = .haveData
                        return true
                    }
                    guard shouldProvideBuffer else {
                        return nil
                    }
                    let bufferPointer = UnsafeMutableRawPointer(bitPattern: bufferAddress)
                    return bufferPointer.map { Unmanaged<AVAudioPCMBuffer>.fromOpaque($0).takeUnretainedValue() }
                }
            }

            if let conversionError {
                let statusSummary = String(describing: status)
                let reason = "converter_status=\(statusSummary):source=\(sourceSummary):buffer=\(bufferSummary):target=\(targetSummary):\(conversionError.localizedDescription)"
                throw VoiceCaptureError.recorderFailed(reason)
            }

            output.append(Self.pcmData(from: converted))

            switch status {
            case .haveData:
                awaitingOutput = converted.frameLength > 0
            case .inputRanDry, .endOfStream:
                awaitingOutput = false
            case .error:
                let reason = "converter_status=error:source=\(sourceSummary):buffer=\(bufferSummary):target=\(targetSummary)"
                throw VoiceCaptureError.recorderFailed(reason)
            @unknown default:
                awaitingOutput = false
            }
        }

        return output
    }

    private func canWriteBufferDirectly(_ buffer: AVAudioPCMBuffer) -> Bool {
        buffer.format.sampleRate == targetFormat.sampleRate &&
            buffer.format.channelCount == targetFormat.channelCount &&
            buffer.format.commonFormat == .pcmFormatInt16 &&
            buffer.format.isInterleaved
    }

    private func describeFormat(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .otherFormat:
            commonFormat = "other"
        case .pcmFormatFloat32:
            commonFormat = "f32"
        case .pcmFormatFloat64:
            commonFormat = "f64"
        case .pcmFormatInt16:
            commonFormat = "i16"
        case .pcmFormatInt32:
            commonFormat = "i32"
        @unknown default:
            commonFormat = "unknown"
        }
        return "\(commonFormat)@\(Int(format.sampleRate)):\(format.channelCount)ch:\(format.isInterleaved ? "int" : "deint")"
    }

    static func pcmData(from buffer: AVAudioPCMBuffer) -> Data {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let dataPointer = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return Data()
        }
        return Data(bytes: dataPointer, count: Int(audioBuffer.mDataByteSize))
    }
}

final class AVAudioEngineRecorderSession: NSObject, VoiceRecorderSession {
    private struct RecorderState {
        var currentFileURL: URL
        var currentHandle: FileHandle?
        var currentFrames: AVAudioFramePosition = 0
        var expectedStop = false
        var recording = false
    }

    private let engine = AVAudioEngine()
    private let sourceFormat: AVAudioFormat
    private let bufferConverter: VoicePCMBufferConverter
    private let repairer = CAFRepairer()
    private let fileManager = FileManager.default
    private let onUnexpectedStop: @Sendable (String) -> Void
    private let onConfigurationChange: @Sendable () -> Void
    private let onStopFinished: @Sendable (Bool) -> Void
    private let state: Mutex<RecorderState>

    init(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws {
        self.onUnexpectedStop = onUnexpectedStop
        self.onConfigurationChange = onConfigurationChange
        self.onStopFinished = onStopFinished
        state = Mutex(RecorderState(currentFileURL: fileURL))

        sourceFormat = try Self.validatedInputFormat(engine.inputNode.outputFormat(forBus: 0))
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: VoiceCAFMuxer.sampleRate,
            channels: VoiceCAFMuxer.channels,
            interleaved: true
        ) else {
            throw VoiceCaptureError.recorderFailed("engine_target_format_unavailable")
        }
        bufferConverter = try VoicePCMBufferConverter(sourceFormat: sourceFormat, targetFormat: targetFormat)
        super.init()

        try installFileHandle(at: fileURL, appendToExisting: appendToExisting)
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: sourceFormat
        ) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine
        )
        engine.prepare()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine
        )
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let handle = state.withLock { state in
            let handle = state.currentHandle
            state.currentHandle = nil
            return handle
        }
        try? handle?.close()
    }

    var fileURL: URL {
        state.withLock { state in
            state.currentFileURL
        }
    }

    var currentTime: TimeInterval {
        state.withLock { state in
            Double(state.currentFrames) / VoiceCAFMuxer.sampleRate
        }
    }

    var isRecording: Bool {
        state.withLock { state in
            state.recording
        }
    }

    func record() -> Bool {
        state.withLock { state in
            state.expectedStop = false
            state.recording = true
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }
            return true
        } catch {
            state.withLock { state in
                state.recording = false
            }
            onUnexpectedStop("engine_start_failed:\(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        let snapshot = state.withLock { state -> (fileURL: URL, handle: FileHandle?)? in
            guard state.recording || state.currentHandle != nil else {
                return nil
            }
            state.expectedStop = true
            state.recording = false
            let handle = state.currentHandle
            state.currentHandle = nil
            return (state.currentFileURL, handle)
        }
        guard let snapshot else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        var success = true
        do {
            try snapshot.handle?.close()
            try finalizeOpenFile(at: snapshot.fileURL)
        } catch {
            success = false
        }
        onStopFinished(success)
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else {
            return
        }

        let writeError = state.withLock { state -> String? in
            guard state.recording, let currentHandle = state.currentHandle else {
                return nil
            }
            do {
                let data = try bufferConverter.convert(buffer)
                guard !data.isEmpty else {
                    return "engine_convert_empty_output"
                }
                try currentHandle.write(contentsOf: data)
                state.currentFrames += AVAudioFramePosition(data.count / Int(VoiceCAFMuxer.bytesPerFrame))
                return nil
            } catch {
                return "engine_convert_failed:\(error.localizedDescription)"
            }
        }
        if let message = writeError {
            signalUnexpectedStop(message)
        }
    }

    private func installFileHandle(at fileURL: URL, appendToExisting: Bool) throws {
        let prepared = try prepareFileHandle(at: fileURL, appendToExisting: appendToExisting)
        state.withLock { state in
            state.currentFileURL = fileURL
            state.currentHandle = prepared.handle
            state.currentFrames = prepared.frames
        }
    }

    private func prepareFileHandle(
        at fileURL: URL,
        appendToExisting: Bool
    ) throws -> (handle: FileHandle, frames: AVAudioFramePosition) {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if appendToExisting, fileManager.fileExists(atPath: fileURL.path) {
            guard var analysis = repairer.analyze(fileURL: fileURL) else {
                throw VoiceCaptureError.recorderFailed("audio_file_unreadable")
            }
            if analysis.status == .needsRepair {
                switch repairer.repair(analysis: analysis) {
                case .success:
                    guard let repaired = repairer.analyze(fileURL: fileURL) else {
                        throw VoiceCaptureError.recorderFailed("audio_file_repair_unreadable")
                    }
                    analysis = repaired
                case let .failed(reason):
                    throw VoiceCaptureError.recorderFailed("audio_file_repair_failed:\(reason)")
                case .notImplemented:
                    throw VoiceCaptureError.recorderFailed("audio_file_repair_not_implemented")
                }
            }
            guard let desc = analysis.descChunk,
                  desc.audioFormat.isCompatible(with: VoiceCAFMuxer.audioFormat),
                  let dataChunk = analysis.dataChunk
            else {
                throw VoiceCaptureError.recorderFailed("audio_file_invalid")
            }

            guard analysis.status == .valid || analysis.status == .emptyData else {
                throw VoiceCaptureError.recorderFailed("audio_file_invalid")
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            let payloadBytes = max(0, analysis.fileSize - Int64(dataChunk.dataOffset))
            let frames = payloadBytes / Int64(VoiceCAFMuxer.bytesPerFrame)
            return (handle, AVAudioFramePosition(frames))
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try VoiceCAFMuxer.writeOpenSegmentHeader(to: fileURL, audioFormat: VoiceCAFMuxer.audioFormat)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        return (handle, 0)
    }

    private func finalizeOpenFile(at fileURL: URL) throws {
        guard let analysis = repairer.analyze(fileURL: fileURL) else {
            throw VoiceCaptureError.recorderFailed("audio_file_finalize_unreadable")
        }

        switch analysis.status {
        case .valid, .emptyData:
            return
        case .needsRepair:
            let payloadBytes = Int(analysis.fileSize) - (analysis.dataChunk?.dataOffset ?? Int(analysis.fileSize))
            if payloadBytes <= 0 {
                try VoiceCAFMuxer.writeClosedSegment(
                    Data(),
                    to: fileURL,
                    audioFormat: analysis.descChunk?.audioFormat ?? VoiceCAFMuxer.audioFormat
                )
                return
            }
            switch repairer.repair(analysis: analysis) {
            case .success:
                return
            case let .failed(reason):
                throw VoiceCaptureError.recorderFailed("audio_file_repair_failed:\(reason)")
            case .notImplemented:
                throw VoiceCaptureError.recorderFailed("audio_file_repair_not_implemented")
            }
        case .tooSmall:
            throw VoiceCaptureError.recorderFailed("audio_file_too_small")
        case .invalidHeader:
            throw VoiceCaptureError.recorderFailed("audio_file_invalid_header")
        case .missingDescChunk:
            throw VoiceCaptureError.recorderFailed("audio_file_missing_desc_chunk")
        case .missingDataChunk:
            throw VoiceCaptureError.recorderFailed("audio_file_missing_data_chunk")
        }
    }

    private func signalUnexpectedStop(_ reason: String) {
        let shouldSignal = state.withLock { state in
            let shouldSignal = !state.expectedStop
            state.recording = false
            return shouldSignal
        }
        guard shouldSignal else {
            return
        }
        onUnexpectedStop(reason)
    }

    @objc
    private func handleEngineConfigurationChange(_: Notification) {
        handleConfigurationChange()
    }

    private func handleConfigurationChange() {
        let shouldSignal = state.withLock { state in
            state.recording || !state.expectedStop
        }
        guard shouldSignal else {
            return
        }
        onConfigurationChange()
    }

    static func validatedInputFormat(_ format: AVAudioFormat) throws -> AVAudioFormat {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceCaptureError.recorderFailed("engine_input_format_invalid")
        }
        return format
    }
}

final class AVAudioRecorderFactory: NSObject, VoiceRecorderFactory {
    func makeRecorder(
        fileURL: URL,
        appendToExisting: Bool,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws -> VoiceRecorderSession {
        _ = onConfigurationChange
        _ = appendToExisting
        return try AVAudioRecorderSession(
            fileURL: fileURL,
            onUnexpectedStop: onUnexpectedStop,
            onStopFinished: onStopFinished
        )
    }
}

private final class AVAudioRecorderSession: NSObject, VoiceRecorderSession, AVAudioRecorderDelegate {
    private struct RecorderState: Sendable {
        var expectedStop = false
    }

    let fileURL: URL
    private let recorder: AVAudioRecorder
    private let onUnexpectedStop: @Sendable (String) -> Void
    private let onStopFinished: @Sendable (Bool) -> Void
    private let state = Mutex(RecorderState())

    init(
        fileURL: URL,
        onUnexpectedStop: @escaping @Sendable (String) -> Void,
        onStopFinished: @escaping @Sendable (Bool) -> Void
    ) throws {
        self.fileURL = fileURL
        self.onUnexpectedStop = onUnexpectedStop
        self.onStopFinished = onStopFinished
        recorder = try AVAudioRecorder(url: fileURL, settings: VoiceCAFMuxer.recordingSettings)
        super.init()
        recorder.delegate = self
        recorder.prepareToRecord()
    }

    var currentTime: TimeInterval {
        recorder.currentTime
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    func record() -> Bool {
        state.withLock { state in
            state.expectedStop = false
        }
        return recorder.record()
    }

    func stop() {
        state.withLock { state in
            state.expectedStop = true
        }
        recorder.stop()
    }
    func audioRecorderDidFinishRecording(_: AVAudioRecorder, successfully flag: Bool) {
        let expectedStop = state.withLock { state in
            state.expectedStop
        }
        if expectedStop {
            onStopFinished(flag)
            return
        }
        guard !flag else {
            return
        }
        onUnexpectedStop("recorder_finished_unsuccessfully")
    }

    func audioRecorderEncodeErrorDidOccur(_: AVAudioRecorder, error: (any Error)?) {
        let expectedStop = state.withLock { state in
            state.expectedStop
        }
        if expectedStop {
            onStopFinished(false)
            return
        }
        onUnexpectedStop(error?.localizedDescription ?? "recorder_encode_error")
    }
}
