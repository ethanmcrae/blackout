import Foundation
import Security

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.local.Blackout"
    private static let account = "unlockPassword"

    static func save(password: String) -> Bool {
        delete()
        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

// MARK: - Password Matcher

final class PasswordMatcher {
    enum Result {
        case correct(position: Int)
        case incorrect
        case complete
    }

    private let characters: [Character]
    private var currentIndex: Int = 0

    init(password: String) {
        self.characters = Array(password)
    }

    func processKey(_ char: Character) -> Result {
        guard !characters.isEmpty else { return .incorrect }

        if char == characters[currentIndex] {
            currentIndex += 1
            if currentIndex >= characters.count {
                currentIndex = 0
                return .complete
            }
            return .correct(position: currentIndex - 1)
        } else {
            currentIndex = 0
            // If the wrong char matches the first password char, advance to 1
            if char == characters[0] {
                currentIndex = 1
            }
            return .incorrect
        }
    }

    func reset() {
        currentIndex = 0
    }
}
