import Foundation

// MARK: - Password Storage

enum KeychainHelper {
    private static let key = "unlockPassword"

    static func save(password: String) -> Bool {
        UserDefaults.standard.set(password, forKey: key)
        return true
    }

    static func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    @discardableResult
    static func delete() -> Bool {
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}

// MARK: - Password Matcher

final class PasswordMatcher {
    enum Result {
        case correct(position: Int)
        case incorrect(previousProgress: Int)
        case complete
    }

    private let characters: [Character]
    private var currentIndex: Int = 0

    var progress: Int { currentIndex }

    init(password: String) {
        self.characters = Array(password)
    }

    func processKey(_ char: Character) -> Result {
        guard !characters.isEmpty else { return .incorrect(previousProgress: 0) }

        if char == characters[currentIndex] {
            currentIndex += 1
            if currentIndex >= characters.count {
                currentIndex = 0
                return .complete
            }
            return .correct(position: currentIndex - 1)
        } else {
            let prev = currentIndex
            currentIndex = 0
            // If the wrong char matches the first password char, advance to 1
            if char == characters[0] {
                currentIndex = 1
            }
            return .incorrect(previousProgress: prev)
        }
    }

    func processBackspace() -> Int {
        if currentIndex > 0 { currentIndex -= 1 }
        return currentIndex
    }

    func reset() {
        currentIndex = 0
    }
}
