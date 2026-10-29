import Foundation
import Network
import Security

/// The server's TLS identity, loaded from the login keychain.
///
/// Encryption exists here for two reasons. The obvious one is that the LAN is
/// treated as untrusted and this app types into Terminal, so plaintext was the
/// largest remaining gap. The less obvious one is that browsers only expose the
/// microphone on a *secure context*: over plain HTTP from a LAN address
/// `navigator.mediaDevices` is not merely blocked, it is undefined. Voice input
/// is impossible without this.
///
/// `scripts/make-tls-cert.sh` creates the certificate and imports it. If no
/// identity is installed, `load()` returns nil and the servers fall back to
/// plaintext — which is also what keeps the test suites able to speak raw TCP.
enum TLSIdentity {

    /// Matches the leaf's common name, which the script sets deliberately so
    /// this lookup is unambiguous.
    static let commonName = "remoteMac TLS"

    /// The helper's own keychain, created by `scripts/make-tls-cert.sh`.
    ///
    /// Deliberately separate from the login keychain. A key there is gated by
    /// both an ACL and a key partition list, and this app is signed with a
    /// local certificate with no Apple team identifier — so it matches none of
    /// the usual partition entries and macOS falls back to asking the user for
    /// their login password. That prompt arrives *mid-handshake*, so every
    /// connection hangs until someone clicks it.
    ///
    /// Owning the keychain removes the question: the script generates its
    /// password, and this unlocks it without involving the user at all.
    private static var keychainDirectory: URL {
        DeckStore.stateDirectory.appendingPathComponent("tls", isDirectory: true)
    }

    private static func openOwnKeychain() -> SecKeychain? {
        let path = keychainDirectory.appendingPathComponent("remotemac.keychain-db").path
        let passwordFile = keychainDirectory.appendingPathComponent("keychain-password")

        guard FileManager.default.fileExists(atPath: path),
              let password = try? String(contentsOf: passwordFile, encoding: .utf8) else {
            return nil
        }

        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return nil }

        // Unlocking every launch is intentional: a keychain that re-locks would
        // fail to produce the key at the one moment it is needed.
        let bytes = Array(password.utf8)
        let status = SecKeychainUnlock(keychain, UInt32(bytes.count), bytes, true)
        guard status == errSecSuccess else {
            NSLog("[TLS] could not unlock the helper keychain (%d)", status)
            return nil
        }
        return keychain
    }

    /// Find the identity by its certificate's common name.
    ///
    /// Scoped to the helper's own keychain via `kSecMatchSearchList`, so the
    /// login keychain is never touched and can never prompt.
    static func load(commonName: String = TLSIdentity.commonName) -> SecIdentity? {
        guard let keychain = openOwnKeychain() else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecMatchSearchList as String: [keychain],
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }

        for identity in identities where certificateName(of: identity) == commonName {
            return identity
        }
        return nil
    }

    private static func certificateName(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// TLS options to hand to an `NWListener`, or nil if no identity exists.
    static func options() -> NWProtocolTLS.Options? {
        guard let identity = load() else { return nil }
        guard let secIdentity = sec_identity_create(identity) else {
            NSLog("[TLS] found the identity but could not wrap it for Network.framework")
            return nil
        }

        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        // 1.2 is the floor; anything older has no business on a new service.
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }
}
