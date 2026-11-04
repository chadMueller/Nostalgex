import Foundation

enum TMDBConfig {
    /// Prefer `Info.plist` keys in production builds; fall back to environment for CI/dev.
    /// Keep these empty by default so the app still compiles without secrets.
    private static let configuredTMDBAPIKey: String = value(forEnv: "TMDB_API_KEY", infoPlistKey: "TMDBApiKey")
    private static let configuredOMDBAPIKey: String = value(forEnv: "OMDB_API_KEY", infoPlistKey: "OMDBApiKey")
    private static let configuredSupabaseURL: String = value(forEnv: "SUPABASE_URL", infoPlistKey: "SupabaseURL")
    private static let configuredSupabaseAnonKey: String = value(forEnv: "SUPABASE_ANON_KEY", infoPlistKey: "SupabaseAnonKey")

    #if DEBUG
    /// Test harnesses only: send TMDB, OMDb (both through the proxy route) and Supabase to
    /// local stand-ins, with no keys, so a run never reaches the real services or the shared
    /// cache. Nil in the app.
    struct HarnessEndpoints {
        let proxyURL: String
        let supabaseURL: String
    }
    nonisolated(unsafe) static var harnessEndpoints: HarnessEndpoints?
    static var tmdbAPIKey: String { harnessEndpoints == nil ? configuredTMDBAPIKey : "" }
    static var omdbAPIKey: String { harnessEndpoints == nil ? configuredOMDBAPIKey : "" }
    static var supabaseURL: String { harnessEndpoints?.supabaseURL ?? configuredSupabaseURL }
    static var supabaseAnonKey: String { harnessEndpoints == nil ? configuredSupabaseAnonKey : "harness" }
    #else
    static var tmdbAPIKey: String { configuredTMDBAPIKey }
    static var omdbAPIKey: String { configuredOMDBAPIKey }
    static var supabaseURL: String { configuredSupabaseURL }
    static var supabaseAnonKey: String { configuredSupabaseAnonKey }
    #endif

    /// The site's TMDB proxy (`api/tmdb.js`). The App Store build carries no TMDB key;
    /// it asks the proxy, which holds the key as a Vercel env var and caches answers at
    /// the edge. A build with `tmdbAPIKey` set (dev) talks to TMDB directly instead.
    #if DEBUG
    static var tmdbProxyURL: String { harnessEndpoints?.proxyURL ?? "https://www.nostalgex.app/api/tmdb" }
    #else
    static let tmdbProxyURL = "https://www.nostalgex.app/api/tmdb"
    #endif

    private static func value(forEnv envKey: String, infoPlistKey: String) -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String, !v.isEmpty {
            return v
        }
        if let v = ProcessInfo.processInfo.environment[envKey], !v.isEmpty {
            return v
        }
        return ""
    }
}
