import Foundation

/// Settings baked in at build time, so pointing the app at the local API or the
/// deployed one is a build setting rather than a code change.
nonisolated enum AppConfig {

    /// From CHEERS_API_URL in the project's build settings, via Info.plist.
    static let apiBaseURL: URL = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CheersAPIURL") as? String,
              let url = URL(string: value)
        else {
            preconditionFailure("CheersAPIURL is missing from Info.plist")
        }
        return url
    }()
}
