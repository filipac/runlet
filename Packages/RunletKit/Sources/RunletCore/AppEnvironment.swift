import Foundation

/// The environment an application reports when a run boots it (#12, N14): Laravel's
/// `app()->environment()`, the Symfony kernel's environment, WordPress's
/// `wp_get_environment_type()`, or a project driver's `environment()`. Only the name travels;
/// the runner reads no other configuration.
public enum AppEnvironment {
    /// Reported names that count as production, compared trimmed and case-insensitively (the
    /// words the SSH config import treats as production). Whole names only: "production-eu",
    /// "preprod", or "prod2" are not production.
    public static let productionNames: Set<String> = ["production", "prod", "prd", "live"]
    /// Reported names that count as a developer's machine (the note on targets marked
    /// production), compared the same way.
    public static let localNames: Set<String> = ["local", "development", "dev"]
    /// The longest name kept; the runner cuts longer ones too.
    public static let maximumLength = 64

    /// A reported name ready to show and store: without control characters, trimmed, at most
    /// `maximumLength` characters; nil when nothing is left.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = printable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Whether `name` is one of `productionNames`.
    public static func isProduction(_ name: String?) -> Bool {
        key(name).map(productionNames.contains) ?? false
    }

    /// Whether `name` is one of `localNames`.
    public static func isLocal(_ name: String?) -> Bool {
        key(name).map(localNames.contains) ?? false
    }

    private static func key(_ name: String?) -> String? {
        normalized(name)?.lowercased()
    }
}

/// What a tab says when the application's reported environment and the target's marking
/// disagree (#12). It never changes a marking and never runs anything: marking the target is
/// the user's choice, and the run that revealed the environment has already happened.
public struct AppEnvironmentNotice: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// The application reports production; the target isn't marked production. Offers Mark
        /// as Production and Dismiss.
        case reportsProduction
        /// The target is marked production; the application reports a local environment.
        /// Information only, with Dismiss: the marking stays and runs keep asking.
        case reportsLocal
    }

    public var kind: Kind
    /// The name the application reported (normalized).
    public var reported: String
    /// How the target was marked when the notice was decided.
    public var marking: TargetEnvironment

    public init(kind: Kind, reported: String, marking: TargetEnvironment) {
        self.kind = kind
        self.reported = reported
        self.marking = marking
    }

    /// The notice for a target, or nil when there is nothing to say: no reported environment,
    /// the sandbox (it can't be marked), a marking that agrees, or a kind the user dismissed
    /// for this target.
    public static func decide(target: TargetRef, marking: TargetEnvironment, reported: String?, dismissed: Set<Kind> = []) -> AppEnvironmentNotice? {
        guard target != .sandbox, let reported = AppEnvironment.normalized(reported) else { return nil }
        let kind: Kind
        if AppEnvironment.isProduction(reported), marking != .production {
            kind = .reportsProduction
        } else if AppEnvironment.isLocal(reported), marking == .production {
            kind = .reportsLocal
        } else {
            return nil
        }
        guard !dismissed.contains(kind) else { return nil }
        return AppEnvironmentNotice(kind: kind, reported: reported, marking: marking)
    }

    /// The banner's text. It says plainly that the run which reported the environment did not
    /// ask first.
    public var message: String {
        switch kind {
        case .reportsProduction:
            let marked = marking == .staging ? "is marked as staging" : "isn't marked as production"
            return "This app reports environment “\(reported)”, but this target \(marked), so that run didn't ask first. Mark it as production to confirm before every run from now on."
        case .reportsLocal:
            return "This target is marked as production, but the app reports environment “\(reported)”. Runlet keeps asking before every run; change the marking in the target's settings if it's wrong."
        }
    }
}
