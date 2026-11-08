import Foundation
import Security

/// The secret two devices share once, so that only they can talk to each other (architecture, section 4).
/// It is shown as 8 groups of 8 hex digits: easy to read out, type or put in a QR code.
public struct PairingKey: Sendable, Equatable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public static func generate() -> PairingKey {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no secure random bytes")
        return PairingKey(bytes: data)!
    }

    /// For example `1a2b3c4d-…` (8 groups).
    public var code: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 64, by: 8).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 8)])
        }.joined(separator: "-")
    }

    /// What a QR code carries: opening it with the iPhone camera starts Musicam and pairs.
    public var pairingLink: String { "musicam://pair?code=\(code)" }

    /// Reads a scanned QR code or a pasted text: either the `musicam://pair?code=…` link or the bare code.
    public init?(scanned text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed), comps.scheme?.lowercased() == "musicam",
           let value = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            self.init(code: value)
        } else if trimmed.contains("://") {
            return nil                                   // some other link: never guess at it
        } else {
            self.init(code: trimmed)
        }
    }

    /// Accepts the code with or without dashes, spaces and capitals.
    public init?(code: String) {
        let cleaned = code.lowercased().filter { $0.isHexDigit }
        guard cleaned.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.init(bytes: data)
    }
}

/// Where the paired key is kept between launches.
public protocol PairingStore: Sendable {
    func load() -> PairingKey?
    func save(_ key: PairingKey)
    func clear()
}

/// The system Keychain (works in the Mac sandbox and on iOS).
public struct KeychainPairingStore: PairingStore {
    private let service: String

    public init(service: String = "com.merajmirbazel.musicam.pairing") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "pairing-key"]
    }

    public func load() -> PairingKey? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return PairingKey(bytes: data)
    }

    public func save(_ key: PairingKey) {
        clear()
        var item = query
        item[kSecValueData as String] = key.bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// A private file inside the app's own folder (mode 0600). Used on macOS, where the app is sandboxed and a
/// Keychain item created by an ad-hoc signed build would ask for permission after every rebuild.
public struct FilePairingStore: PairingStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PairingKey? {
        guard let code = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PairingKey(code: code)
    }

    public func save(_ key: PairingKey) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? key.code.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keeps the key in memory only (tests and previews).
public final class MemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: PairingKey?
    public init(key: PairingKey? = nil) { self.key = key }
    public func load() -> PairingKey? { lock.lock(); defer { lock.unlock() }; return key }
    public func save(_ key: PairingKey) { lock.lock(); self.key = key; lock.unlock() }
    public func clear() { lock.lock(); key = nil; lock.unlock() }
}
