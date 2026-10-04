import Foundation

/// What runs on a target do with mail, and where that comes from (#193): the output header's
/// mail chip and its popover. `TargetLibrary.mailInterception(for:global:runInspector:)` builds it.
public struct MailInterception: Sendable, Equatable {
    /// Where the effective mode comes from.
    public enum Source: String, Sendable, Equatable {
        /// The target's own Mail option (a local project, Docker profile, or SSH profile).
        case target
        /// Settings ▸ General ▸ Run Inspector ▸ Intercept mail.
        case settings
    }

    /// What the mail chip shows.
    public enum State: String, Sendable, Equatable {
        /// Runs ask drivers to record mail without sending it. Interception keeps the inspector
        /// on for the run, so this is the state whether or not the run inspector setting is on.
        case intercepting
        /// Runs send mail, and the inspector records it.
        case sending
        /// Runs send mail and record nothing: the run inspector is off.
        case inspectorOff
    }

    /// Whether runs ask drivers to intercept mail (the same as `TargetLibrary.interceptMail(for:global:)`).
    public var intercept: Bool
    public var source: Source
    /// The target's own Mail option, which the editors' Mail picker shows: nil follows Settings.
    public var override: Bool?
    /// Whether the target has a Mail option of its own. The sandbox and missing targets don't:
    /// they follow Settings.
    public var hasOption: Bool
    public var state: State

    public init(intercept: Bool, source: Source, override: Bool?, hasOption: Bool, state: State) {
        self.intercept = intercept
        self.source = source
        self.override = override
        self.hasOption = hasOption
        self.state = state
    }

    /// Whether choosing `choice` in the chip's Mail picker asks first: only when it makes a
    /// production target send mail that it intercepted until now (Send, or Default while
    /// Settings says Send). Intercept, and choices that keep the target sending, never ask.
    public func asksFirst(choosing choice: Bool?, global: Bool, production: Bool) -> Bool {
        production && intercept && !(choice ?? global)
    }
}

extension TargetLibrary {
    /// The target's own Mail option: nil when it follows Settings or has no option (the sandbox).
    public func interceptMailOverride(for target: TargetRef) -> Bool? {
        switch target {
        case .sandbox: nil
        case .local(let id): localProject(id)?.interceptMail
        case .docker(let id): dockerProfile(id)?.interceptMail
        case .ssh(let id): sshProfile(id)?.interceptMail
        }
    }

    /// Whether `target` is a saved local project, Docker profile, or SSH profile, the targets
    /// with a Mail option of their own.
    public func hasMailOption(_ target: TargetRef) -> Bool {
        switch target {
        case .sandbox: false
        case .local(let id): localProject(id) != nil
        case .docker(let id): dockerProfile(id) != nil
        case .ssh(let id): sshProfile(id) != nil
        }
    }

    /// The mail chip's mode for `target` (#193). `global` is Settings ▸ Intercept mail and
    /// `runInspector` Settings ▸ Record queries, mail, and logs.
    public func mailInterception(for target: TargetRef, global: Bool, runInspector: Bool) -> MailInterception {
        let override = interceptMailOverride(for: target)
        let intercept = override ?? global
        let state: MailInterception.State = intercept ? .intercepting : runInspector ? .sending : .inspectorOff
        return MailInterception(intercept: intercept, source: override == nil ? .settings : .target, override: override,
                                hasOption: hasMailOption(target), state: state)
    }
}

extension InspectorInfo {
    /// The run's warning when it asked for interception and no driver confirmed it. The mail
    /// chip quotes the last such run on a target (#193), so support is what runs report, not a
    /// list of drivers.
    public var interceptionWarning: String? {
        guard interceptionUnsupported else { return nil }
        let driver = driverName.map { "the \($0) driver" } ?? "this project's driver"
        return "Intercept Mail is on, but \(driver) can't intercept mail. Mail this run sends is delivered normally."
    }
}
