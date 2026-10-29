import Foundation

/// Every message this server sends, in one place.
///
/// Replies used to be assembled inline with string interpolation, and the one
/// field whose text varies — a validator's rejection reason — was hand-escaped
/// at each call site, in two different files. That is how a stray quote turns a
/// reply into a frame the client cannot parse. Variable text now goes through
/// `JSONSerialization`, and the constant frames are literals, which cannot be
/// malformed at all.
enum Reply {

    // MARK: - Control socket (v1 envelope)

    static let pong          = #"{"v":1,"t":"pong"}"#
    static let welcome       = #"{"v":1,"t":"welcome"}"#
    static let authRequired  = #"{"v":1,"t":"auth.required"}"#
    static let authFailed    = #"{"v":1,"t":"auth.failed"}"#
    static let authTimeout   = #"{"v":1,"t":"auth.timeout"}"#
    static let busy          = #"{"v":1,"t":"busy"}"#
    static let paused        = #"{"v":1,"t":"paused"}"#
    static let resumed       = #"{"v":1,"t":"resumed"}"#
    static let deckSaved     = #"{"v":1,"t":"deck.saved"}"#

    static func focus(text: Bool) -> String {
        #"{"v":1,"t":"focus","text":\#(text)}"#
    }

    /// The only reply carrying text that did not originate as a literal. The
    /// reason always describes protocol *shape* — never message content.
    static func error(_ reason: String) -> String {
        #"{"v":1,"t":"error","reason":\#(JSON.string(reason))}"#
    }

    /// Payloads that are already-encoded JSON produced on this side of the wire
    /// (the validated deck, the enumerated app list). They are embedded as-is
    /// rather than parsed and re-serialized, which would only be a way to
    /// mistrust our own encoder.
    static func deck(_ encodedDeck: String) -> String {
        #"{"v":1,"t":"deck","deck":\#(encodedDeck)}"#
    }

    static func apps(_ encodedApps: String) -> String {
        #"{"v":1,"t":"apps","apps":\#(encodedApps)}"#
    }

    // MARK: - HTTP bodies

    /// Non-secret wiring information for the page. A port number is not a
    /// credential, so this is reachable unauthenticated like the page itself.
    static func config(controlPort: UInt16, accessibility: Bool) -> String {
        #"{"v":1,"controlPort":\#(controlPort),"accessibility":\#(accessibility)}"#
    }

    static func pairingToken(_ token: String) -> String {
        #"{"token":\#(JSON.string(token))}"#
    }

    static func pairingError(_ code: String) -> String {
        #"{"error":\#(JSON.string(code))}"#
    }

    static func pairingThrottled(retryAfter seconds: Int) -> String {
        #"{"error":"throttled","retryAfter":\#(seconds)}"#
    }
}

/// The one JSON primitive this project needs: encode a Swift `String` as a JSON
/// string literal, quotes included.
enum JSON {
    static func string(_ value: String) -> String {
        // `.fragmentsAllowed` lets a bare string be encoded without wrapping it
        // in an array or object first.
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.fragmentsAllowed]),
              let encoded = String(data: data, encoding: .utf8) else {
            return #""""#
        }
        return encoded
    }
}
