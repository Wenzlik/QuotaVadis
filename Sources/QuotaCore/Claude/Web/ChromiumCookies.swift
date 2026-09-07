import Foundation
#if os(macOS)
import CommonCrypto
import CryptoKit
import SQLite3
import Security
#endif

/// Reads cookies from a Chromium/Electron `Cookies` SQLite store and decrypts the macOS "v10" values with the
/// app's Safe Storage key (Keychain item "<App> Safe Storage"). Used for the Claude desktop app and Chrome.
public struct ChromiumCookieStore: Sendable {
    public let path: String
    /// Keychain service/account of the Safe Storage password, e.g. ("Claude Safe Storage", "Claude").
    public let keychainService: String
    public let keychainAccount: String

    public init(path: String, keychainService: String, keychainAccount: String) {
        self.path = path; self.keychainService = keychainService; self.keychainAccount = keychainAccount
    }

    public static let claudeDesktop = ChromiumCookieStore(
        path: NSHomeDirectory() + "/Library/Application Support/Claude/Cookies",
        keychainService: "Claude Safe Storage", keychainAccount: "Claude")

    public static func chromeProfiles() -> [ChromiumCookieStore] {
        let root = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .map { ChromiumCookieStore(path: "\(root)/\($0)/Cookies", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Decrypted value of `name` for a host ending in `domain`, or nil.
    public func value(name: String, domain: String) throws -> String? {
        #if os(macOS)
        guard exists else { return nil }
        // Copy first: the owning app may hold the database locked, and we must never write next to it.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qv-cookies-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(atPath: path, toPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ProviderError.decoding("cannot open cookie store") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT host_key, value, encrypted_value FROM cookies WHERE name = ? ORDER BY expires_utc DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ProviderError.decoding("cannot query cookie store") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var key: Data?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            guard host.hasSuffix(domain) else { continue }
            if let plain = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), !plain.isEmpty { return plain }
            let length = Int(sqlite3_column_bytes(stmt, 2))
            guard length > 3, let bytes = sqlite3_column_blob(stmt, 2) else { continue }
            let encrypted = Data(bytes: bytes, count: length)
            if key == nil { key = try Self.deriveKey(password: try safeStoragePassword()) }
            if let value = Self.decrypt(encrypted, key: key!, hostKey: host) { return value }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    func safeStoragePassword() throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        ProviderInteractionContext.suppressUIIfBackground(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw status == errSecItemNotFound ? ProviderError.notLoggedIn : ProviderError.keychainDenied
        }
        return password
    }

    static func deriveKey(password: String) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw ProviderError.decoding("key derivation failed") }
        return key
    }

    /// "v10" + AES-128-CBC(IV = 16 spaces). Chromium ≥ 130 prefixes the plaintext with SHA256(host_key).
    static func decrypt(_ encrypted: Data, key: Data, hostKey: String) -> String? {
        guard encrypted.count > 3, String(data: encrypted.prefix(3), encoding: .utf8) == "v10" else { return nil }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, payload.count, outBytes.baseAddress, outBytes.count, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
        if out.count > 32, out.prefix(32) == digest { out = out.dropFirst(32) }
        else if out.count > 32, String(data: out, encoding: .utf8) == nil { out = out.dropFirst(32) }
        return String(data: out, encoding: .utf8)
    }
    #endif
}
