import Foundation

public enum CaptureFilenameSemantics {
    public static func readableFilenameStem(_ filename: String) -> String? {
        let rawStem = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawStem.isEmpty else {
            return nil
        }
        guard isOpaqueTransportName(rawStem) == false else {
            return nil
        }
        return rawStem
    }

    private static func isOpaqueTransportName(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        guard !normalized.isEmpty else {
            return true
        }

        let uuidLike = normalized.range(
            of: #"^[A-Fa-f0-9]{8}[A-Fa-f0-9]{4}[A-Fa-f0-9]{4}[A-Fa-f0-9]{4}[A-Fa-f0-9]{12}$"#,
            options: .regularExpression
        ) != nil
        if uuidLike {
            return true
        }

        let hexLike = normalized.range(
            of: #"^[A-Fa-f0-9]{24,}$"#,
            options: .regularExpression
        ) != nil
        return hexLike
    }
}
