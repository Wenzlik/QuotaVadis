import Foundation
#if os(macOS)
import SQLite3
#endif

/// Reads Cursor.app's access token from its VS Code-style global state database (read-only).
struct CursorCredentials: Sendable {
    let accessToken: String
    let userID: String
    let email: String?
    let expiresAt: Date?

    static var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    }

    static func isAvailable() -> Bool { FileManager.default.fileExists(atPath: stateDBPath) }

    /// Cursor's web session cookie is `<userID>::<jwt>`.
    var cookieHeader: String { "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)" }

    static func load() throws -> CursorCredentials {
        guard isAvailable() else { throw ProviderError.notInstalled }
        #if os(macOS)
        guard let token = try readValue(key: "cursorAuth/accessToken"), !token.isEmpty else {
            throw ProviderError.notLoggedIn
        }
        return try parse(token: token)
        #else
        throw ProviderError.notInstalled
        #endif
    }

    static func parse(token: String) throws -> CursorCredentials {
        let claims = JWT.payload(token) ?? [:]
        guard let sub = claims["sub"] as? String,
              let userID = sub.split(separator: "|").last.map(String.init), !userID.isEmpty else {
            throw ProviderError.decoding("Cursor token has no user id")
        }
        return CursorCredentials(accessToken: token, userID: userID, email: claims["email"] as? String, expiresAt: JWT.expiry(token))
    }

    #if os(macOS)
    private static func readValue(key: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ProviderError.decoding("cannot open Cursor state database")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError.decoding("cannot query Cursor state database")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if let text = sqlite3_column_text(stmt, 0) { return String(cString: text) }
        return nil
    }
    #endif
}
