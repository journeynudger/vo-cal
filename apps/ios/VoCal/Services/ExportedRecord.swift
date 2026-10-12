import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The person's whole record as one JSON file (`GET /account/export`; the Rams review's R11:
/// the record is on our rail, so the person must be able to leave with it). Fetched when the
/// share sheet asks for it, never before, and handed over as bytes: the system sheet and the
/// person's choice of destination, nothing of ours in between.
struct ExportedRecord: Transferable {
    /// How the bytes are fetched: the live API, or a small canned file on the sim.
    let fetch: @Sendable () async throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { record in
            let data = try await record.fetch()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vo-cal-record.json")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    static func live(api: APIClient) -> ExportedRecord {
        ExportedRecord {
            // The export needs the account's session, as every read does on a cold launch.
            await AuthCoordinator.shared.ensureSession()
            return try await api.exportRecord()
        }
    }

    /// The sim has no account to export; the file says so instead of pretending.
    static let mock = ExportedRecord {
        Data("{\"format\": 1, \"note\": \"Simulator mock data. The live export carries every table the person owns.\"}".utf8)
    }
}
