import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    struct Operations {
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var add: (CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus

        static let system = Operations(
            update: { SecItemUpdate($0, $1) },
            add: { SecItemAdd($0, nil) },
            delete: { SecItemDelete($0) }
        )
    }

    struct AccessError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            return L10n.text("store.keychain_failed", reason)
        }
    }

    private static let service = "com.backupcron.database-passwords"
    private static let legacyService = "ru.backupflow.database-passwords"

    static func password(for jobID: UUID) -> String {
        if let password = password(for: jobID, service: service) {
            return password
        }
        if let password = password(for: jobID, service: legacyService) {
            // A failed migration must not make a readable legacy password disappear.
            try? setPassword(password, for: jobID)
            return password
        }
        return ""
    }

    private static func password(for jobID: UUID, service: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: jobID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func setPassword(_ password: String, for jobID: UUID, operations: Operations = .system) throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: jobID.uuidString,
            kSecUseAuthenticationContext as String: context
        ]

        if password.isEmpty {
            try deletePassword(for: jobID, operations: operations)
            return
        }

        let data = Data(password.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = operations.update(baseQuery as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            try check(operations.add(addQuery as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func deletePassword(for jobID: UUID, operations: Operations = .system) throws {
        // Remove both entries so explicitly clearing a password cannot bring
        // an old credential back through the legacy migration fallback.
        // Clear legacy first: a failure must not expose an older credential
        // by deleting the modern entry while leaving the fallback in place.
        let context = LAContext()
        context.interactionNotAllowed = true
        for itemService in [legacyService, service] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: itemService,
                kSecAttrAccount as String: jobID.uuidString,
                kSecUseAuthenticationContext as String: context
            ]
            let status = operations.delete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AccessError(status: status) }
    }
}
