import Foundation
import Security

// Port provenance: Serein apps/ios/Shared/Sources/AppGroupConfig.swift.
// Renames: group.com.serein.shared → group.com.vocal.shared; Serein* Info.plist keys →
// VoCal* keys; com.serein.device.identity → com.vocal.device.identity.
// Seam cut: the iCloud container helpers (configuredICloudContainerIdentifier,
// iCloudContainerURL) are not ported. Requirement: Vo-Cal's data plane is the local
// app-group container plus the Supabase API — iCloud Drive must never be part of any
// path. Failure mode avoided: an agent "finding" an iCloud helper and putting ubiquity
// storage on the capture or commit path, which Serein's doctrine explicitly forbids
// ("Do not make iCloud Drive ... part of the critical path"). Evidence: Serein
// AGENTS.md data-plane guardrails; Vo-Cal AGENTS.md repository layout (no iCloud).

enum AppGroupConfig {
    static let defaultIdentifier = "group.com.vocal.shared"
    static let infoPlistKey = "VoCalAppGroupID"

    static func configuredIdentifier(bundle: Bundle = .main) -> String {
        guard let configured = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !configured.isEmpty
        else {
            return defaultIdentifier
        }
        return configured
    }

    static func sharedContainerURL(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) throws -> URL {
        let identifier = configuredIdentifier(bundle: bundle)
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw AppGroupConfigError.missingContainer(identifier: identifier)
        }
        return url
    }
}

enum SharedKeychainConfig {
    static let infoPlistKey = "VoCalSharedKeychainAccessGroup"

    static func configuredAccessGroup(bundle: Bundle = .main) -> String? {
        guard let configured = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func query(
        service: String,
        account: String,
        bundle: Bundle = .main
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup = configuredAccessGroup(bundle: bundle) {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}

enum AppGroupConfigError: LocalizedError {
    case missingContainer(identifier: String)

    var errorDescription: String? {
        switch self {
        case let .missingContainer(identifier):
            return "App Group container is unavailable for identifier \(identifier)."
        }
    }
}

enum DeviceIdentityStore {
    enum Error: Swift.Error, LocalizedError {
        case unexpectedData
        case keychainStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedData:
                return "device_identity_unexpected_data"
            case let .keychainStatus(status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return "device_identity_keychain_error:\(status):\(message)"
                }
                return "device_identity_keychain_error:\(status)"
            }
        }
    }

    private static let service = "com.vocal.device.identity"
    private static let account = "producer_device_id_v1"

    static func loadOrCreateDeviceID(bundle: Bundle = .main) throws -> String {
        if let existing = try readDeviceID(bundle: bundle) {
            return existing
        }

        let newID = "ios-\(UUID().uuidString.lowercased())"
        return try writeDeviceID(newID, bundle: bundle)
    }

    private static func readDeviceID(bundle: Bundle = .main) throws -> String? {
        var query = SharedKeychainConfig.query(
            service: service,
            account: account,
            bundle: bundle
        )
        query.merge([
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8)
            else {
                throw Error.unexpectedData
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Error.unexpectedData
            }
            return trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw Error.keychainStatus(status)
        }
    }

    private static func writeDeviceID(_ deviceID: String, bundle: Bundle = .main) throws -> String {
        let data = Data(deviceID.utf8)
        var addQuery = SharedKeychainConfig.query(
            service: service,
            account: account,
            bundle: bundle
        )
        addQuery.merge([
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return deviceID
        case errSecDuplicateItem:
            if let existing = try readDeviceID(bundle: bundle) {
                return existing
            }
            let matchQuery = SharedKeychainConfig.query(
                service: service,
                account: account,
                bundle: bundle
            )
            let updateAttrs: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw Error.keychainStatus(updateStatus)
            }
            return deviceID
        default:
            throw Error.keychainStatus(addStatus)
        }
    }
}
