import Foundation
import Security

public protocol LocalAPISecretStore: Sendable {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

public enum KeychainSecretStoreError: LocalizedError, Sendable {
    case invalidEncoding
    case operationFailed(OSStatus)
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "The secret could not be encoded securely."
        case .operationFailed(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain operation failed: \(detail)."
        case .randomGenerationFailed(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Secure token generation failed: \(detail)."
        }
    }
}

/// Small, injectable boundary around the user's login Keychain. Secrets are
/// device-bound and are unavailable to cloud backups or other user accounts.
public struct KeychainSecretStore: LocalAPISecretStore, Sendable {
    public static let webhookSigningSecretAccount = "meeting-webhook-signing-secret"
    public static let localAPITokenAccount = "local-api-token"

    private let service: String

    public init(service: String = "com.tumcuctom.evee") {
        self.service = service
    }

    public func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretStoreError.operationFailed(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.invalidEncoding
        }
        return value
    }

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainSecretStoreError.invalidEncoding }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainSecretStoreError.operationFailed(updateStatus) }

        var insertion = query
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainSecretStoreError.operationFailed(addStatus) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.operationFailed(status)
        }
    }

    public static func randomToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainSecretStoreError.randomGenerationFailed(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
