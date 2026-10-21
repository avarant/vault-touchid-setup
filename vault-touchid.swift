import Foundation
import Security
import LocalAuthentication
import CryptoKit

let serviceName = "vault-token"
let unsealServiceName = "vault-unseal-keys"
let accountName = "default"

// Each secret is encrypted to its own Secure Enclave key that can only be used after TouchID.
// The Secure Enclave enforces the biometric check, so patching or injecting code into this
// program cannot recover the secret. The keychain only holds the encrypted envelope.
struct Envelope: Codable {
    let seKey: Data              // Secure Enclave key blob, usable only by this Mac's Secure Enclave
    let ephemeralPublicKey: Data
    let sealedBox: Data          // AES-GCM nonce + ciphertext + tag
}

func fail(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}

func deriveKey(_ shared: SharedSecret, ephemeralPublicKey: Data, seKeyPublic: Data, service: String) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: ephemeralPublicKey + seKeyPublic,
        sharedInfo: Data(service.utf8),
        outputByteCount: 32
    )
}

func sealSecret(_ plaintext: Data, service: String) -> Data {
    guard SecureEnclave.isAvailable else {
        fail("Secure Enclave not available on this Mac.")
    }
    guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet],
        nil
    ) else {
        fail("Failed to create access control.")
    }

    do {
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: seKey.publicKey)
        let key = deriveKey(
            shared,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            seKeyPublic: seKey.publicKey.rawRepresentation,
            service: service
        )
        let box = try AES.GCM.seal(plaintext, using: key)
        let envelope = Envelope(
            seKey: seKey.dataRepresentation,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            sealedBox: box.combined!
        )
        return try JSONEncoder().encode(envelope)
    } catch {
        fail("Encryption failed: \(error.localizedDescription)")
    }
}

func openSecret(_ stored: Data, service: String, reason: String) -> Data {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: stored) else {
        fail("Stored item uses the old unprotected format. Re-run: vault-dev --setup")
    }

    let context = LAContext()
    var laError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &laError) else {
        fail("TouchID not available: \(laError?.localizedDescription ?? "unknown")")
    }
    context.localizedReason = reason

    do {
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: envelope.seKey,
            authenticationContext: context
        )
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey)
        // The Secure Enclave shows the TouchID prompt here and refuses without a match
        let shared = try seKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = deriveKey(
            shared,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            seKeyPublic: seKey.publicKey.rawRepresentation,
            service: service
        )
        return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealedBox), using: key)
    } catch {
        fail("Authentication failed: \(error.localizedDescription)\n"
            + "If you changed your enrolled fingerprints, re-run: vault-dev --setup")
    }
}

func writeItem(service: String, data: Data) -> OSStatus {
    // Delete any existing entry first
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: accountName,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: accountName,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    return SecItemAdd(addQuery as CFDictionary, nil)
}

func readItem(service: String, missingMessage: String) -> Data {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: accountName,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
        guard let data = result as? Data else {
            fail("Failed to read keychain item.")
        }
        return data
    case errSecItemNotFound:
        fputs("\(missingMessage)\n", stderr)
        exit(1)
    default:
        fail("Keychain error: OSStatus \(status)")
    }
}

func store() {
    guard let input = readLine(strippingNewline: true), !input.isEmpty else {
        fail("No token provided on stdin.")
    }

    let status = writeItem(service: serviceName, data: sealSecret(Data(input.utf8), service: serviceName))
    if status == errSecSuccess {
        fputs("Vault token stored successfully.\n", stderr)
        exit(0)
    } else {
        fail("Failed to store token (OSStatus \(status)).")
    }
}

func retrieve() {
    let stored = readItem(service: serviceName, missingMessage: "No vault token stored. Run setup first.")
    let data = openSecret(stored, service: serviceName, reason: "Access Vault token")
    guard let token = String(data: data, encoding: .utf8) else {
        fail("Failed to decode token.")
    }
    print(token, terminator: "")
    exit(0)
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
        fail("Failed to delete token (OSStatus \(status)).")
    }
}

func storeUnsealKeys() {
    var keys: [String] = []
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { break }
        keys.append(line)
    }

    guard !keys.isEmpty else {
        fail("No unseal keys provided.")
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: keys) else {
        fail("Failed to serialize keys.")
    }

    let status = writeItem(service: unsealServiceName, data: sealSecret(jsonData, service: unsealServiceName))
    if status == errSecSuccess {
        fputs("Stored \(keys.count) unseal key(s) successfully.\n", stderr)
        exit(0)
    } else {
        fail("Failed to store unseal keys (OSStatus \(status)).")
    }
}

func retrieveUnsealKeys() {
    let stored = readItem(service: unsealServiceName, missingMessage: "No unseal keys stored. Run setup first.")
    let data = openSecret(stored, service: unsealServiceName, reason: "Access Vault unseal keys")
    guard let keys = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        fail("Failed to decode unseal keys.")
    }
    for key in keys {
        print(key)
    }
    exit(0)
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
