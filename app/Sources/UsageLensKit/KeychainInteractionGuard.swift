import Foundation
import LocalAuthentication
import Security

public enum KeychainInteractionGuard {
    @discardableResult
    public static func disableUserInteraction() -> OSStatus {
        SecKeychainSetUserInteractionAllowed(false)
    }

    public static func isUserInteractionAllowed() -> Bool? {
        var allowed: DarwinBoolean = true
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else { return nil }
        return allowed.boolValue
    }

    public static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    internal static func upsertAppOwnedItem(
        baseQuery: [String: Any],
        value: Data,
        update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        delete: (CFDictionary) -> OSStatus = { SecItemDelete($0) },
        add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> OSStatus {
        disableUserInteraction()
        let status = update(baseQuery as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        switch status {
        case errSecSuccess:
            return errSecSuccess
        case errSecItemNotFound:
            break
        case errSecInteractionNotAllowed, errSecAuthFailed:
            disableUserInteraction()
            let deleteStatus = delete(baseQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return deleteStatus
            }
        default:
            return status
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        disableUserInteraction()
        return add(addQuery as CFDictionary)
    }
}
