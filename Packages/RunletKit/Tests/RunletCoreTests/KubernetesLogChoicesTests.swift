import Testing
@testable import RunletCore

struct KubernetesLogChoicesTests {
    private let fixture = KubernetesTests()

    @Test func automaticResolutionNeverBecomesStickyConsent() {
        var profile = fixture.profile()
        let first = fixture.pod("web-0"), replacement = fixture.pod("web-0", uid: "new")
        var choices = KubernetesLogChoices()
        #expect(choices.resolve(profile, pods: [first]) == .resolved(first))
        #expect(choices.choice(for: profile) == nil)
        #expect(choices.resolve(profile, pods: [replacement]) == .resolved(replacement))
        profile.interchangeableReplicas = true
        let newer = fixture.pod("web-1", created: "2026-02-01")
        #expect(choices.resolve(profile, pods: [first, newer]) == .resolved(first))
        #expect(choices.resolve(profile, pods: [replacement, newer]) == .resolved(replacement))
        #expect(choices.choice(for: profile) == nil)
        profile.pinnedPod = first.identity
        #expect(choices.resolve(profile, pods: [first, newer]) == .resolved(first))
        #expect(choices.choice(for: profile) == nil)
        if case .unavailable = choices.resolve(profile, pods: [replacement, newer]) {} else { Issue.record("A pin must refuse a replacement") }
        profile.pinnedPod = newer.identity
        #expect(choices.resolve(profile, pods: [replacement, newer]) == .resolved(newer))
    }

    @Test(arguments: [false, true])
    func explicitChoiceSurvivesSourcesAndRequiresFreshConsentAfterReplacement(interchangeable: Bool) {
        var profile = fixture.profile()
        profile.interchangeableReplicas = interchangeable
        let a = fixture.pod("a"), b = fixture.pod("b"), replacement = fixture.pod("b", uid: "replacement")
        var choices = KubernetesLogChoices()
        choices.select(b.identity, for: profile)
        // A new source takes the target's choice; repeated Follow/Find Logs never default to a.
        #expect(choices.choice(for: profile)?.pod == b.identity)
        #expect(choices.resolve(profile, pods: [a, b]) == .resolved(b))
        #expect(choices.resolve(profile, pods: [b, a]) == .resolved(b))
        #expect(choices.resolve(profile, pods: [replacement]) == .ambiguous([replacement]))
        #expect(choices.choice(for: profile)?.pod == nil)
        // Switching sources cannot reseed the deleted identity from a stale tab choice.
        choices.preselect(KubernetesTabChoice(profile: profile, pod: b.identity), for: profile)
        #expect(choices.choice(for: profile)?.pod == nil)
        if case .unavailable = choices.resolve(profile, pods: []) {} else { Issue.record("No pod is eligible") }
        #expect(choices.resolve(profile, pods: [replacement]) == .ambiguous([replacement]))
        choices.select(replacement.identity, for: profile)
        #expect(choices.resolve(profile, pods: [replacement]) == .resolved(replacement))
    }

    @Test func tabPreselectionIsExplicitAndNeverOverridesViewerConsent() {
        let profile = fixture.profile(), a = fixture.pod("a"), b = fixture.pod("b")
        var choices = KubernetesLogChoices()
        choices.preselect(KubernetesTabChoice(profile: profile, pod: b.identity), for: profile)
        #expect(choices.resolve(profile, pods: [a, b]) == .resolved(b))
        choices.select(a.identity, for: profile)
        choices.preselect(KubernetesTabChoice(profile: profile, pod: b.identity), for: profile)
        #expect(choices.resolve(profile, pods: [a, b]) == .resolved(a))
    }

    @Test func choicesArePerTargetAndClearedOnSaveRevisionChangeAndClose() {
        var profile = fixture.profile()
        let other = fixture.profile(), a = fixture.pod("a"), b = fixture.pod("b")
        var choices = KubernetesLogChoices()
        choices.select(a.identity, for: profile)
        choices.select(b.identity, for: other)
        #expect(choices.resolve(profile, pods: [a, b]) == .resolved(a))
        #expect(choices.resolve(other, pods: [a, b]) == .resolved(b))
        choices.remove(profile.id) // Save Profile removes only this target's choice.
        #expect(choices.resolve(profile, pods: [a, b]) == .ambiguous([a, b]))
        #expect(choices.choice(for: other)?.pod == b.identity)
        choices.select(a.identity, for: profile)
        profile.revision += 1
        #expect(choices.choice(for: profile) == nil)
        #expect(choices.resolve(profile, pods: [a, b]) == .ambiguous([a, b]))
        choices.removeAll() // Closing Logs clears all targets and invalidation markers.
        #expect(choices.choice(for: other) == nil)
        #expect(choices.resolve(other, pods: [a, b]) == .ambiguous([a, b]))
    }
}
