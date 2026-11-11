import Foundation
import Testing
@testable import QuotaCore

struct GoodDataAccountDetectorTests {
    private func snapshot(_ provider: ProviderID, account: String? = nil, organization: String? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: provider, account: account, organization: organization, plan: nil, windows: [], deviceName: "Test")
    }

    @Test func matchesGoodDataEmailCaseInsensitively() {
        #expect(GoodDataAccountDetector.isGoodDataEmail("jane.doe@gooddata.com"))
        #expect(GoodDataAccountDetector.isGoodDataEmail("Jane.Doe@GoodData.COM"))
        #expect(GoodDataAccountDetector.isGoodDataEmail("  jane@gooddata.com \n"))
        #expect(GoodDataAccountDetector.isGoodDataEmail("jane@gooddata.com."))       // trailing root dot
        #expect(GoodDataAccountDetector.isGoodDataEmail("\"a@b\"@gooddata.com"))      // last @ decides
    }

    @Test func matchesSubdomains() {
        #expect(GoodDataAccountDetector.isGoodDataEmail("jane@eu.gooddata.com"))
        #expect(GoodDataAccountDetector.isGoodDataEmail("jane@mail.EU.GoodData.com"))
    }

    @Test func rejectsLookalikesAndJunk() {
        for email in ["jane@gooddata.com.evil.io", "jane@notgooddata.com", "jane@gooddata.co", "jane@gooddata.ai",
                      "jane@gooddata-com.io", "jane@evil.io?gooddata.com", "gooddata.com", "jane.gooddata.com",
                      "@gooddata.com", "jane@", "jane@.gooddata.com", "jane@eu..gooddata.com", "jane@gooddata.com..",
                      "jane@gooddata.com@evil.io", "", "   "] {
            #expect(!GoodDataAccountDetector.isGoodDataEmail(email), "\(email)")
        }
        #expect(!GoodDataAccountDetector.isGoodDataEmail(nil))
    }

    @Test func matchesOrganizationExactlyIgnoringCaseAndWhitespace() {
        for name in ["GoodData", "gooddata", "GOODDATA", "  GoodData  ", "GoodData.AI", "gooddata.ai", "\tGoodData.ai\n"] {
            #expect(GoodDataAccountDetector.isGoodDataOrganization(name), "\(name)")
        }
        for name in ["Not GoodData", "gooddata-test", "GoodData Inc", "Good Data", "gooddata.com", "GoodData.AI.", "", nil] as [String?] {
            #expect(!GoodDataAccountDetector.isGoodDataOrganization(name), "\(String(describing: name))")
        }
    }

    @Test func oneMatchingSnapshotOfAnyProviderIsEnough() {
        #expect(!GoodDataAccountDetector.isGoodData([]))
        #expect(!GoodDataAccountDetector.isGoodData([snapshot(.claude), snapshot(.codex, account: "me@example.com")]))
        #expect(GoodDataAccountDetector.isGoodData([snapshot(.claude, account: "me@example.com"),
                                                    snapshot(.cursor, account: "me@GoodData.com")]))
        #expect(GoodDataAccountDetector.isGoodData([snapshot(.claude, account: "me@example.com", organization: "GoodData")]))
        #expect(GoodDataAccountDetector.isGoodData([snapshot(.gemini, account: "me@eu.gooddata.com")]))
        #expect(!GoodDataAccountDetector.isGoodData([snapshot(.claude, account: "me@gooddata.ai", organization: "Not GoodData")]))
    }

    @Test func detectionSurvivesSyncRoundTrip() throws {
        // iOS gets snapshots through CloudKit/App Group JSON; account and organization must come through.
        let original = snapshot(.claude, account: "me@gooddata.com", organization: "Personal")
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        #expect(GoodDataAccountDetector.isGoodData([decoded]))
    }
}

struct AppThemeTests {
    private let gooddata = [UsageSnapshot(provider: .codex, account: "me@gooddata.com", plan: nil, windows: [], deviceName: "Test")]
    private let other = [UsageSnapshot(provider: .codex, account: "me@example.com", plan: nil, windows: [], deviceName: "Test")]

    @Test func autoFollowsDetection() {
        #expect(AppTheme.auto.resolved(for: gooddata) == .goodLimits)
        #expect(AppTheme.auto.resolved(for: other) == .standard)
        #expect(AppTheme.auto.resolved(for: []) == .standard)
    }

    @Test func manualChoiceAlwaysWins() {
        for theme in [AppTheme.standard, .observatory, .goodLimits] {
            #expect(theme.resolved(for: gooddata) == theme)
            #expect(theme.resolved(for: other) == theme)
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "AppThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func migratesLegacyObservatoryToggle() {
        let defaults = freshDefaults()
        #expect(AppTheme.stored(in: defaults) == .auto)
        defaults.set(false, forKey: AppTheme.legacyObservatoryKey)
        #expect(AppTheme.stored(in: defaults) == .auto)
        defaults.set(true, forKey: AppTheme.legacyObservatoryKey)
        #expect(AppTheme.stored(in: defaults) == .observatory)
        #expect(AppTheme.migrate(defaults) == .observatory)
        #expect(defaults.string(forKey: AppTheme.storageKey) == "observatory")
    }

    @Test func explicitChoiceBeatsLegacyToggle() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: AppTheme.legacyObservatoryKey)
        defaults.set(AppTheme.standard.rawValue, forKey: AppTheme.storageKey)
        #expect(AppTheme.stored(in: defaults) == .standard)
        defaults.set("bogus", forKey: AppTheme.storageKey)
        #expect(AppTheme.stored(in: defaults) == .observatory)   // unreadable choice: fall back to migration
        defaults.removeObject(forKey: AppTheme.legacyObservatoryKey)
        #expect(AppTheme.migrate(defaults) == .auto)
        #expect(defaults.string(forKey: AppTheme.storageKey) == "auto")
    }
}
