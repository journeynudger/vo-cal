import Foundation

public struct CaptureRelayConfig: Sendable {
    public let baseURL: URL
    public let environmentLabel: String

    public init(baseURL: URL, environmentLabel: String) {
        self.baseURL = baseURL
        self.environmentLabel = environmentLabel
    }

    public static func load(bundle: Bundle = .main) -> CaptureRelayConfig? {
        let rawURL = (bundle.object(forInfoDictionaryKey: "VoCalCaptureRelayBaseURL") as? String) ?? ""
        guard let url = URL(string: rawURL), !rawURL.isEmpty else {
            return nil
        }
        let environment = (bundle.object(forInfoDictionaryKey: "VoCalCaptureRelayEnvironment") as? String) ?? "alpha"
        return CaptureRelayConfig(
            baseURL: url,
            environmentLabel: environment
        )
    }
}
