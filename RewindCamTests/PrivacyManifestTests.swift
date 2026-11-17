import Foundation
import Testing

/// The unit tests are hosted in the app, so `Bundle.main` is the built `RewindCam.app`.
/// These checks fail if the privacy manifest stops being copied into the bundle
/// (for example if XcodeGen puts it in the wrong build phase) or loses an entry.
@Suite("Privacy manifest")
struct PrivacyManifestTests {

    private func loadManifest() throws -> [String: Any] {
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is missing from \(Bundle.main.bundleURL.lastPathComponent)"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func manifestIsInTheAppBundle() throws {
        #expect(Bundle.main.bundleURL.lastPathComponent == "RewindCam.app")
        _ = try loadManifest()
    }

    @Test func declaresNoTrackingAndNoCollectedData() throws {
        let manifest = try loadManifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    @Test func declaresRequiredReasonAPIs() throws {
        let manifest = try loadManifest()
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in entries {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        // UserDefaults (UserDefaultsSettingsStore: settings, and Dim's brightness to restore, #38): app-only
        // defaults -> CA92.1.
        // volumeAvailableCapacityForImportantUsageKey (VolumeDiskCapacity, the low-disk guard of issue #10):
        // check there is enough space to write files -> E174.1.
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        ])
    }
}
