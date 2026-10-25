import Foundation

public enum UpkinVersion {
    /// The bundle version; `swift run` has no Info.plist, so fall back to the release this source tree describes.
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

public enum UpkinPreferences {
    public static func migrate(defaults: UserDefaults = .standard,
                               legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.local.CodexLimitBar")) {
        guard !defaults.bool(forKey: "upkinPreferencesMigrated") else { return }
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "upkinPreferencesMigrated")
    }
}
