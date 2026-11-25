import Foundation

/// Opt-in settings for native continuation after a provider's turn-limit error.
/// This source-branch addition is available only after integration and rebuild;
/// it does not describe a setting already shipped in the user's installed app.
///
/// Callers must first classify a real provider failure. Enabling this policy
/// alone is never a trigger, and local message / tool / agent-loop counts must
/// not be used to infer a provider limit. Re-read before creating a successor
/// so turning the setting off also prevents a pending automatic continuation.
enum ContinuationPolicy {
    /// The config registry and Settings UI use this exact same storage key.
    static let settingsKey = "chat.autoContinueOnTurnLimit"
    static let defaultValue = false

    /// Stop automatic continuation once the chain reaches this failure count.
    /// The continuation coordinator owns counting and resetting the chain.
    static let maxConsecutiveFailures = 3

    /// Intentionally not cached: config API and Settings changes take effect
    /// on the next decision, without restarting the app or the conversation.
    static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    /// Injectable storage keeps Standalone tests away from real app settings.
    /// Match AppStorageBoolField's unset fallback and bool conversion exactly.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: settingsKey) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: settingsKey)
    }
}
