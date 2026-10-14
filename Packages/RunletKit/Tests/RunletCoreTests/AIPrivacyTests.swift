import Foundation
import Testing
@testable import RunletCore

/// #368: what a request sends is what the disclosure shows, part by part, and only what the
/// user approved.
struct AIPrivacyTests {
    static func disclosure() -> AIDisclosure {
        AIDisclosure(provider: .openai, model: "gpt-6-astra", instructions: "Be brief.",
                     history: [AIMessage(.user, "Earlier question"), AIMessage(.assistant, "Earlier answer")],
                     parts: [AIDisclosurePart(id: "a", title: "First", text: "one"),
                             AIDisclosurePart(id: "b", title: "Second", text: "two", isIncluded: false),
                             AIDisclosurePart(id: "c", title: "Third", text: "three")],
                     maxOutputTokens: 500)
    }

    @Test func onlyIncludedPartsAreSent() {
        var disclosure = Self.disclosure()
        #expect(disclosure.message == "## First\n\none\n\n## Third\n\nthree")
        let request = disclosure.request(stream: true)
        #expect(request.messages == [AIMessage(.user, "Earlier question"), AIMessage(.assistant, "Earlier answer"), AIMessage(.user, disclosure.message)])
        #expect(request.instructions == "Be brief.")
        #expect(request.model == "gpt-6-astra")
        #expect(request.stream)
        #expect(!disclosure.request(stream: false).stream)
        disclosure.setIncluded("b", true)
        #expect(disclosure.message.contains("## Second\n\ntwo"))
        disclosure.setIncluded("missing", false)
        #expect(disclosure.characterCount == "Be brief.".count + "Earlier question".count + "Earlier answer".count + disclosure.message.count)
    }

    @Test func emptyWhenNothingIsIncluded() {
        var disclosure = Self.disclosure()
        #expect(!disclosure.isEmpty)
        disclosure.setIncluded("a", false)
        disclosure.setIncluded("c", false)
        #expect(disclosure.isEmpty)
        #expect(disclosure.message.isEmpty)
    }

    @Test func consentCoversOnlyWhatWasShown() {
        let shown = Self.disclosure()
        let consent = AIConsent(approving: shown)
        #expect(consent.covers(shown))
        var toggled = shown
        toggled.setIncluded("b", true)
        #expect(!consent.covers(toggled))
        var edited = shown
        edited.parts[0].text = "one, edited"
        #expect(!consent.covers(edited))
        var provider = shown
        provider.provider = .anthropic
        #expect(!consent.covers(provider))
        var instructions = shown
        instructions.instructions = "Be long."
        #expect(!consent.covers(instructions))
    }

    @Test func longTextIsShortenedWithANote() {
        let short = AITextLimit.clamp("abc", limit: 10)
        #expect(short.text == "abc")
        #expect(short.note == nil)
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let long = AITextLimit.clamp(lines, limit: 100)
        #expect(long.text.hasPrefix("line 1\nline 2"))
        // Cut at a line break, and the text says how much is missing.
        #expect(long.text.contains("\n[… "))
        #expect(long.text.hasSuffix("more characters left out]"))
        #expect(!long.text.contains("line 50"))
        #expect(long.note?.hasPrefix("Only the first") == true)
    }
}
