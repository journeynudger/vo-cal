import Foundation
import Testing
@testable import VoCalVoice

/// CAFRepairer truncation detection. A file whose data-chunk header claims more audio than
/// the file actually holds (crash / disk-full after the size was written) must NOT be reported
/// .valid with an over-stated duration — it must route to .needsRepair so the header is
/// rewritten to the bytes that survived (audio is ground truth; no false durability claims).
struct CAFRepairerTests {
    // 'caff' / 'desc' / 'data' magic, big-endian.
    private static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private static func be16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private static func be64i(_ v: Int64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private static func be64u(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    /// Build a CAF with a fully-formed header + desc chunk and a data chunk whose header declares
    /// `declaredPayload` bytes of audio while only `actualPayload` bytes are appended.
    private func makeCAF(declaredPayload: Int64, actualPayload: Int) -> Data {
        var bytes: [UInt8] = []
        // file header: 'caff', version 1, flags 0
        bytes += Self.be32(0x63616666); bytes += Self.be16(1); bytes += Self.be16(0)
        // desc chunk: 'desc', size 32, then 32-byte ASBD
        bytes += Self.be32(0x64657363); bytes += Self.be64i(32)
        bytes += Self.be64u(Float64(48000).bitPattern)  // sampleRate
        bytes += Self.be32(0x6C70636D)                  // 'lpcm'
        bytes += Self.be32(0)                            // formatFlags
        bytes += Self.be32(2)                            // bytesPerPacket
        bytes += Self.be32(1)                            // framesPerPacket
        bytes += Self.be32(1)                            // channelsPerFrame
        bytes += Self.be32(16)                           // bitsPerChannel
        // data chunk: 'data', declaredSize (= 4 editCount + declaredPayload), editCount 0, payload
        bytes += Self.be32(0x64617461); bytes += Self.be64i(4 + declaredPayload)
        bytes += Self.be32(0)                            // editCount
        bytes += [UInt8](repeating: 0xAB, count: actualPayload)
        return Data(bytes)
    }

    private let url = URL(fileURLWithPath: "/tmp/vocal-caf-test.caf")

    @Test("A data chunk that fits the file is valid")
    func matchingSizeIsValid() {
        let data = makeCAF(declaredPayload: 100, actualPayload: 100)
        let analysis = CAFRepairer().analyze(data: data, fileURL: url)
        #expect(analysis?.status == .valid)
    }

    @Test("A data chunk claiming more bytes than the file holds is truncated → needsRepair")
    func overrunIsTruncatedAndRepairs() {
        let data = makeCAF(declaredPayload: 1000, actualPayload: 100)
        let analysis = CAFRepairer().analyze(data: data, fileURL: url)
        #expect(analysis?.status == .needsRepair)
        // Duration must reflect the bytes that actually survived, not the (larger) declared size.
        // 100 bytes / 2 bytesPerPacket / 48000 Hz.
        #expect((analysis?.estimatedAudioDuration ?? -1) == 100.0 / 2.0 / 48000.0)
    }
}
