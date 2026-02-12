import Foundation
import Security
import LocalAuthentication

let serviceName = "vault-token"
let unsealServiceName = "vault-unseal-keys"
let accountName = "default"

func store() {
    guard let input = readLine(strippingNewline: true), !input.isEmpty else {
        fputs("Error: No token provided on stdin.\n", stderr)
        exit(1)
    }
    guard let tokenData = input.data(using: .utf8) else {
        fputs("Error: Invalid token data.\n", stderr)
        exit(1)
    }

    // Delete any existing entry first
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    // Store in the regular keychain (no biometric ACL — TouchID is enforced via LAContext on retrieve)
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
        kSecValueData as String: tokenData,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
        fputs("Vault token stored successfully.\n", stderr)
        exit(0)
    } else {
        fputs("Error: Failed to store token (OSStatus \(status)).\n", stderr)
        exit(1)
    }
}

func retrieve() {
    // Require TouchID before accessing the token
    let context = LAContext()
    var laError: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError) else {
        fputs("Error: TouchID not available: \(laError?.localizedDescription ?? "unknown")\n", stderr)
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var authSuccess = false

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: "Access Vault token"
    ) { success, error in
        if success {
            authSuccess = true
        } else if let error = error as? LAError {
            switch error.code {
            case .userCancel:
                fputs("Authentication cancelled.\n", stderr)
            case .userFallback:
                fputs("Authentication fallback not supported.\n", stderr)
            default:
                fputs("Authentication failed: \(error.localizedDescription)\n", stderr)
            }
        }
        semaphore.signal()
    }

    semaphore.wait()

    guard authSuccess else {
        exit(1)
    }

    // TouchID succeeded — now read from keychain
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            fputs("Error: Failed to decode token.\n", stderr)
            exit(1)
        }
        print(token, terminator: "")
        exit(0)
    case errSecItemNotFound:
        fputs("No vault token stored. Run setup first.\n", stderr)
        exit(1)
    default:
        fputs("Keychain error: OSStatus \(status)\n", stderr)
        exit(1)
    }
}

func delete() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
    ]

    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess {
        fputs("Vault token deleted.\n", stderr)
        exit(0)
    } else if status == errSecItemNotFound {
        fputs("No vault token found.\n", stderr)
        exit(0)
    } else {
        fputs("Error: Failed to delete token (OSStatus \(status)).\n", stderr)
        exit(1)
    }
}

func storeUnsealKeys() {
    var keys: [String] = []
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { break }
        keys.append(line)
    }

    guard !keys.isEmpty else {
        fputs("Error: No unseal keys provided.\n", stderr)
        exit(1)
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: keys) else {
        fputs("Error: Failed to serialize keys.\n", stderr)
        exit(1)
    }

    // Delete any existing entry first
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: unsealServiceName,
        kSecAttrAccount as String: accountName,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: unsealServiceName,
        kSecAttrAccount as String: accountName,
        kSecValueData as String: jsonData,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
        fputs("Stored \(keys.count) unseal key(s) successfully.\n", stderr)
        exit(0)
    } else {
        fputs("Error: Failed to store unseal keys (OSStatus \(status)).\n", stderr)
        exit(1)
    }
}

func retrieveUnsealKeys() {
    // Require TouchID before accessing the keys
    let context = LAContext()
    var laError: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError) else {
        fputs("Error: TouchID not available: \(laError?.localizedDescription ?? "unknown")\n", stderr)
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var authSuccess = false

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: "Access Vault unseal keys"
    ) { success, error in
        if success {
            authSuccess = true
        } else if let error = error as? LAError {
            switch error.code {
            case .userCancel:
                fputs("Authentication cancelled.\n", stderr)
            default:
                fputs("Authentication failed: \(error.localizedDescription)\n", stderr)
            }
        }
        semaphore.signal()
    }

    semaphore.wait()

    guard authSuccess else {
        exit(1)
    }

    // TouchID succeeded — now read from keychain
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: unsealServiceName,
        kSecAttrAccount as String: accountName,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
        guard let data = result as? Data,
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            fputs("Error: Failed to decode unseal keys.\n", stderr)
            exit(1)
        }
        for key in keys {
            print(key)
        }
        exit(0)
    case errSecItemNotFound:
        fputs("No unseal keys stored. Run setup first.\n", stderr)
        exit(1)
    default:
        fputs("Keychain error: OSStatus \(status)\n", stderr)
        exit(1)
    }
}

// Main
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: vault-touchid <store|retrieve|delete|store-unseal-keys|retrieve-unseal-keys>\n", stderr)
    exit(1)
}

switch CommandLine.arguments[1] {
case "store":
    store()
case "retrieve":
    retrieve()
case "delete":
    delete()
case "store-unseal-keys":
    storeUnsealKeys()
case "retrieve-unseal-keys":
    retrieveUnsealKeys()
default:
    fputs("Unknown command: \(CommandLine.arguments[1])\n", stderr)
    fputs("Usage: vault-touchid <store|retrieve|delete|store-unseal-keys|retrieve-unseal-keys>\n", stderr)
    exit(1)
}
