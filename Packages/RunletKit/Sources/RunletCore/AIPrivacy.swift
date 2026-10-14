import Foundation

// The privacy rules every AI feature shares (#368), kept in one place:
//
// 1. Nothing is sent automatically. A request leaves only through `AIClient.stream` or
//    `complete`, which need an `AIConsent`, and only a click on a feature's Send button makes
//    one (`AIConsent(approving:)`), for the disclosure on screen at that moment.
// 2. The user sees exactly what will be sent before sending: an `AIDisclosure` holds the
//    provider, the model, the instructions, and every part of the message, each with its own
//    switch. The request is built from the disclosure (`request(stream:)`), and the client
//    refuses one that differs from what was approved (`AIError.notConfirmed`).
// 3. Generated code is never run. Answers are text; applying a proposed change replaces the
//    tab's code like an edit (undoable, and it turns off sandbox auto-run), and running it is
//    the user's Run, with production's confirmation as always.

/// One part of what a request sends, shown with a switch (#368): the error, the code, a file's
/// source. Only included parts are sent.
public struct AIDisclosurePart: Sendable, Equatable, Identifiable {
    public var id: String
    /// What the part is, in sentence case: "The error", "The tab's code".
    public var title: String
    /// Its exact text, as sent.
    public var text: String
    public var isIncluded: Bool
    /// A note under the part, such as what was left out of a long one.
    public var note: String?

    public init(id: String, title: String, text: String, isIncluded: Bool = true, note: String? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.isIncluded = isIncluded
        self.note = note
    }
}

/// Exactly what a request will send, shown before it's sent (#368).
public struct AIDisclosure: Sendable, Equatable {
    public var provider: AIProvider
    public var model: String
    /// The system prompt, shown too: it goes to the provider with the message.
    public var instructions: String
    /// Earlier turns of a conversation, sent as they are (a chat, #45); empty for one question.
    public var history: [AIMessage]
    /// The new message's parts.
    public var parts: [AIDisclosurePart]
    public var maxOutputTokens: Int
    public var effort: AIEffort?

    public init(provider: AIProvider, model: String, instructions: String, history: [AIMessage] = [], parts: [AIDisclosurePart], maxOutputTokens: Int, effort: AIEffort? = nil) {
        self.provider = provider
        self.model = model
        self.instructions = instructions
        self.history = history
        self.parts = parts
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
    }

    /// The new message: each included part under its title, as "## Title" and the text.
    public var message: String {
        parts.filter(\.isIncluded).map { "## \($0.title)\n\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Whether anything would be sent.
    public var isEmpty: Bool { !parts.contains { $0.isIncluded && !$0.text.isEmpty } }

    /// Characters sent: the instructions, the earlier turns, and the message.
    public var characterCount: Int {
        instructions.count + history.reduce(0) { $0 + $1.text.count } + message.count
    }

    /// The request this disclosure sends, and nothing else.
    public func request(stream: Bool) -> AIRequest {
        AIRequest(provider: provider, model: model, instructions: instructions, messages: history + [AIMessage(.user, message)],
                  maxOutputTokens: maxOutputTokens, effort: effort, stream: stream)
    }

    public mutating func setIncluded(_ id: String, _ included: Bool) {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        parts[index].isIncluded = included
    }
}

/// The user's click on Send for one disclosure (#368). `AIClient` sends a request only with a
/// consent that covers it: the same provider, model, instructions, and message the user saw.
/// Features create one only in their Send button's action, never on their own.
public struct AIConsent: Sendable, Equatable {
    public let approved: AIRequest

    public init(approving disclosure: AIDisclosure) {
        approved = disclosure.request(stream: false)
    }

    /// Whether the disclosure is what the user approved (streaming or not is the feature's
    /// choice, not the user's).
    public func covers(_ disclosure: AIDisclosure) -> Bool {
        approved == disclosure.request(stream: false)
    }
}

/// Text that's too long for a request, shortened (#368): the first `limit` characters, cut at a
/// line break when one is near, and a note that says what was left out.
public enum AITextLimit {
    public static func clamp(_ text: String, limit: Int) -> (text: String, note: String?) {
        guard text.count > limit else { return (text, nil) }
        var kept = String(text.prefix(limit))
        if let newline = kept.lastIndex(of: "\n"), kept.distance(from: newline, to: kept.endIndex) < 400 {
            kept = String(kept[..<newline])
        }
        let left = text.count - kept.count
        return (kept + "\n[… \(left) more characters left out]", "Only the first \(kept.count.formatted()) characters are sent; \(left.formatted()) more are left out.")
    }
}
