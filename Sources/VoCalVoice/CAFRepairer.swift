import AudioToolbox
import Foundation

public struct CAFRepairer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func analyze(fileURL: URL) -> CAFAnalysis? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return analyze(data: data, fileURL: fileURL)
    }

    public func analyze(data: Data, fileURL: URL) -> CAFAnalysis? {
        guard data.count >= CAFConstants.minFileSize else {
            return CAFAnalysis(
                fileURL: fileURL,
                fileSize: Int64(data.count),
                isValidCAF: false,
                status: .tooSmall,
                descChunk: nil,
                dataChunk: nil,
                estimatedAudioDuration: nil
            )
        }

        guard let fileHeader = parseFileHeader(data: data), fileHeader.isValid else {
            return CAFAnalysis(
                fileURL: fileURL,
                fileSize: Int64(data.count),
                isValidCAF: false,
                status: .invalidHeader,
                descChunk: nil,
                dataChunk: nil,
                estimatedAudioDuration: nil
            )
        }

        guard let descChunk = parseDescChunk(data: data, offset: CAFConstants.fileHeaderSize) else {
            return CAFAnalysis(
                fileURL: fileURL,
                fileSize: Int64(data.count),
                isValidCAF: false,
                status: .missingDescChunk,
                descChunk: nil,
                dataChunk: nil,
                estimatedAudioDuration: nil
            )
        }

        let dataChunk = findDataChunk(
            data: data,
            startOffset: CAFConstants.fileHeaderSize + 12 + Int(descChunk.chunkSize)
        )

        let status: CAFStatus
        var estimatedDuration: TimeInterval?

        if let dataChunk {
            let actualDataSize: Int64
            if dataChunk.declaredSize == -1 {
                actualDataSize = Int64(data.count) - Int64(dataChunk.dataOffset)
            } else if dataChunk.declaredSize >= 4 {
                actualDataSize = dataChunk.declaredSize - 4
            } else {
                actualDataSize = 0
            }

            if descChunk.audioFormat.sampleRate > 0 && descChunk.audioFormat.bytesPerPacket > 0 {
                let totalSamples = actualDataSize / Int64(descChunk.audioFormat.bytesPerPacket)
                estimatedDuration = Double(totalSamples) / descChunk.audioFormat.sampleRate
            }

            if dataChunk.declaredSize == -1 {
                status = .needsRepair
            } else if actualDataSize > 0 {
                status = .valid
            } else {
                status = .emptyData
            }
        } else {
            status = .missingDataChunk
        }

        return CAFAnalysis(
            fileURL: fileURL,
            fileSize: Int64(data.count),
            isValidCAF: status == .valid || status == .needsRepair,
            status: status,
            descChunk: descChunk,
            dataChunk: dataChunk,
            estimatedAudioDuration: estimatedDuration
        )
    }

    public func repair(analysis: CAFAnalysis) -> RepairResult {
        guard analysis.status == .needsRepair else {
            return .failed(reason: "file status is \(analysis.status)")
        }
        guard let descChunk = analysis.descChunk,
              let dataChunk = analysis.dataChunk else {
            return .failed(reason: "missing desc or data chunk")
        }
        guard let originalData = try? Data(contentsOf: analysis.fileURL, options: .mappedIfSafe) else {
            return .failed(reason: "could not read original file")
        }

        let actualDataSize = Int(analysis.fileSize) - dataChunk.dataOffset
        guard actualDataSize > 0 else {
            return .failed(reason: "no audio data to repair")
        }

        var repairedData = Data()
        appendCAFFileHeader(to: &repairedData)
        appendDescChunk(to: &repairedData, audioFormat: descChunk.audioFormat)
        appendDataChunkHeader(to: &repairedData, chunkSize: Int64(4 + actualDataSize))

        let audioDataRange = dataChunk.dataOffset..<originalData.count
        guard audioDataRange.upperBound <= originalData.count else {
            return .failed(reason: "audio data range out of bounds")
        }
        repairedData.append(originalData[audioDataRange])

        let tempURL = analysis.fileURL.deletingPathExtension().appendingPathExtension("repair.caf")
        let backupURL = analysis.fileURL.deletingPathExtension().appendingPathExtension("backup.caf")

        do {
            try repairedData.write(to: tempURL, options: .atomic)
            guard let repairedAnalysis = analyze(fileURL: tempURL),
                  repairedAnalysis.status == .valid else {
                try? fileManager.removeItem(at: tempURL)
                return .failed(reason: "repaired file failed validation")
            }

            try? fileManager.removeItem(at: backupURL)
            try fileManager.moveItem(at: analysis.fileURL, to: backupURL)
            try fileManager.moveItem(at: tempURL, to: analysis.fileURL)
            try? fileManager.removeItem(at: backupURL)
            return .success(repairedURL: analysis.fileURL, duration: analysis.estimatedAudioDuration ?? 0)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return .failed(reason: "file operation failed: \(error.localizedDescription)")
        }
    }

    private func appendCAFFileHeader(to data: inout Data) {
        var magic = CAFConstants.caffMagic.bigEndian
        var version = UInt16(1).bigEndian
        var flags = UInt16(0).bigEndian
        data.append(Data(bytes: &magic, count: MemoryLayout.size(ofValue: magic)))
        data.append(Data(bytes: &version, count: MemoryLayout.size(ofValue: version)))
        data.append(Data(bytes: &flags, count: MemoryLayout.size(ofValue: flags)))
    }

    private func appendDescChunk(to data: inout Data, audioFormat: CAFAudioFormat) {
        var chunkType = CAFConstants.descChunkType.bigEndian
        var chunkSize = Int64(32).bigEndian
        data.append(Data(bytes: &chunkType, count: MemoryLayout.size(ofValue: chunkType)))
        data.append(Data(bytes: &chunkSize, count: MemoryLayout.size(ofValue: chunkSize)))

        var sampleRate = audioFormat.sampleRate.bitPattern.bigEndian
        var formatID = audioFormat.formatID.bigEndian
        var formatFlags = audioFormat.formatFlags.bigEndian
        var bytesPerPacket = audioFormat.bytesPerPacket.bigEndian
        var framesPerPacket = audioFormat.framesPerPacket.bigEndian
        var channelsPerFrame = audioFormat.channelsPerFrame.bigEndian
        var bitsPerChannel = audioFormat.bitsPerChannel.bigEndian

        data.append(Data(bytes: &sampleRate, count: MemoryLayout.size(ofValue: sampleRate)))
        data.append(Data(bytes: &formatID, count: MemoryLayout.size(ofValue: formatID)))
        data.append(Data(bytes: &formatFlags, count: MemoryLayout.size(ofValue: formatFlags)))
        data.append(Data(bytes: &bytesPerPacket, count: MemoryLayout.size(ofValue: bytesPerPacket)))
        data.append(Data(bytes: &framesPerPacket, count: MemoryLayout.size(ofValue: framesPerPacket)))
        data.append(Data(bytes: &channelsPerFrame, count: MemoryLayout.size(ofValue: channelsPerFrame)))
        data.append(Data(bytes: &bitsPerChannel, count: MemoryLayout.size(ofValue: bitsPerChannel)))
    }

    private func appendDataChunkHeader(to data: inout Data, chunkSize: Int64) {
        var chunkType = CAFConstants.dataChunkType.bigEndian
        var actualChunkSize = chunkSize.bigEndian
        var editCount = UInt32(0).bigEndian

        data.append(Data(bytes: &chunkType, count: MemoryLayout.size(ofValue: chunkType)))
        data.append(Data(bytes: &actualChunkSize, count: MemoryLayout.size(ofValue: actualChunkSize)))
        data.append(Data(bytes: &editCount, count: MemoryLayout.size(ofValue: editCount)))
    }

    private func parseFileHeader(data: Data) -> CAFFileHeader? {
        guard data.count >= CAFConstants.fileHeaderSize else {
            return nil
        }
        let fileType = data.readUInt32BE(at: 0)
        let version = data.readUInt16BE(at: 4)
        let flags = data.readUInt16BE(at: 6)
        guard let fileType, let version, let flags else {
            return nil
        }
        return CAFFileHeader(mFileType: fileType, mFileVersion: version, mFileFlags: flags)
    }

    private func parseDescChunk(data: Data, offset: Int) -> CAFDescChunk? {
        guard data.count >= offset + 12 + 32 else {
            return nil
        }
        guard let chunkType = data.readUInt32BE(at: offset),
              let chunkSize = data.readInt64BE(at: offset + 4),
              chunkType == CAFConstants.descChunkType,
              chunkSize == 32
        else {
            return nil
        }
        guard let sampleRateBits = data.readUInt64BE(at: offset + 12),
              let formatID = data.readUInt32BE(at: offset + 20),
              let formatFlags = data.readUInt32BE(at: offset + 24),
              let bytesPerPacket = data.readUInt32BE(at: offset + 28),
              let framesPerPacket = data.readUInt32BE(at: offset + 32),
              let channelsPerFrame = data.readUInt32BE(at: offset + 36),
              let bitsPerChannel = data.readUInt32BE(at: offset + 40) else {
            return nil
        }

        return CAFDescChunk(
            chunkSize: chunkSize,
            audioFormat: CAFAudioFormat(
                sampleRate: Double(bitPattern: sampleRateBits),
                formatID: formatID,
                formatFlags: formatFlags,
                bytesPerPacket: bytesPerPacket,
                framesPerPacket: framesPerPacket,
                channelsPerFrame: channelsPerFrame,
                bitsPerChannel: bitsPerChannel
            )
        )
    }

    private func findDataChunk(data: Data, startOffset: Int) -> CAFDataChunk? {
        var offset = startOffset
        while data.count >= offset + 12 {
            guard let chunkType = data.readUInt32BE(at: offset),
                  let chunkSize = data.readInt64BE(at: offset + 4) else {
                return nil
            }

            if chunkType == CAFConstants.dataChunkType {
                let dataOffset = offset + 12 + 4
                return CAFDataChunk(chunkOffset: offset, declaredSize: chunkSize, dataOffset: dataOffset)
            }

            if chunkSize <= 0 {
                break
            }
            offset += 12 + Int(chunkSize)
        }
        return nil
    }
}

private enum CAFConstants {
    static let fileHeaderSize = 8
    static let minFileSize = 8 + 12 + 32
    static let caffMagic: UInt32 = 0x63616666
    static let descChunkType: UInt32 = 0x64657363
    static let dataChunkType: UInt32 = 0x64617461
}

public struct CAFAnalysis: Sendable, Equatable {
    public let fileURL: URL
    public let fileSize: Int64
    public let isValidCAF: Bool
    public let status: CAFStatus
    public let descChunk: CAFDescChunk?
    public let dataChunk: CAFDataChunk?
    public let estimatedAudioDuration: TimeInterval?
}

public enum CAFStatus: Sendable, Equatable {
    case valid
    case needsRepair
    case tooSmall
    case invalidHeader
    case missingDescChunk
    case missingDataChunk
    case emptyData
}

public struct CAFFileHeader: Sendable, Equatable {
    public let mFileType: UInt32
    public let mFileVersion: UInt16
    public let mFileFlags: UInt16

    public var isValid: Bool {
        mFileType == CAFConstants.caffMagic && mFileVersion == 1
    }
}

public struct CAFAudioFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let channelsPerFrame: UInt32
    public let bitsPerChannel: UInt32

    public init(
        sampleRate: Double,
        formatID: UInt32,
        formatFlags: UInt32,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
    }

    public var isLPCM: Bool {
        formatID == kAudioFormatLinearPCM
    }

    public func isCompatible(with expected: CAFAudioFormat) -> Bool {
        formatID == expected.formatID &&
        abs(sampleRate - expected.sampleRate) < 0.000_1 &&
        bytesPerPacket == expected.bytesPerPacket &&
        framesPerPacket == expected.framesPerPacket &&
        channelsPerFrame == expected.channelsPerFrame &&
        bitsPerChannel == expected.bitsPerChannel
    }
}

public struct CAFDescChunk: Sendable, Equatable {
    public let chunkSize: Int64
    public let audioFormat: CAFAudioFormat
}

public struct CAFDataChunk: Sendable, Equatable {
    public let chunkOffset: Int
    public let declaredSize: Int64
    public let dataOffset: Int
}

public enum RepairResult: Sendable, Equatable {
    case success(repairedURL: URL, duration: TimeInterval)
    case failed(reason: String)
    case notImplemented
}

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else {
            return nil
        }
        return withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            return UInt16(bigEndian: value)
        }
    }

    func readUInt32BE(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else {
            return nil
        }
        return withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return UInt32(bigEndian: value)
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64? {
        guard count >= offset + 8 else {
            return nil
        }
        return withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return UInt64(bigEndian: value)
        }
    }

    func readInt64BE(at offset: Int) -> Int64? {
        guard count >= offset + 8 else {
            return nil
        }
        return withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            return Int64(bigEndian: value)
        }
    }
}
