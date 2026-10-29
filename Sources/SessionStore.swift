import CryptoKit
import Foundation

/// Pairing and session tokens.
///
/// The PIN is a *bootstrap secret only*: six digits is ~20 bits, which is fine
/// for a value you read off a menu bar once and worthless as a standing
/// credential. So it is generated fresh each launch, never persisted, rate
/// limited, and good only for exchanging into a 256-bit random session token.
///
/// Deriving the long-lived token *from* the PIN would undo all of that — the
/// credential space would still be 10^6, and a constant salt would make one
/// precomputed table work against every installation. The token is therefore
/// independent CSPRNG output, and only its SHA-256 is stored, at mode 0600, so
/// the file on disk is not itself a credential.
final class SessionStore {
    struct Device: Codable {
        let hash: String       // hex SHA-256 of the token
        let label: String
        let created: Date
    }

    private struct Persisted: Codable {
        var devices: [Device]
    }

    private let lock = NSLock()
    private var devices: [Device] = []

    /// Fresh per launch, never written to disk. Pairing a new device needs physical
    /// access to the Mac's menu bar, which is the trust anchor for the whole scheme.
    private var _pin: String

    // Throttling state for PIN attempts.
    private var failures = 0
    private var lockedUntil: Date?

    private static let maxFreeAttempts = 5
    private static let baseLockout: TimeInterval = 30
    private static let maxLockout: TimeInterval = 15 * 60

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SessionStore.defaultFileURL()
        _pin = SessionStore.generatePIN()
        devices = load()
    }

    private static func defaultFileURL() -> URL {
        DeckStore.stateDirectory.appendingPathComponent("session.json")
    }

    // MARK: - PIN

    var pin: String {
        lock.lock(); defer { lock.unlock() }
        return _pin
    }

    /// Six digits from the system CSPRNG. `Int.random(in:)` uses
    /// SystemRandomNumberGenerator, which is cryptographically secure on Apple
    /// platforms — but six digits is only ~20 bits, which is why it buys a token
    /// rather than acting as one.
    private static func generatePIN() -> String {
        String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
    }

    func regeneratePIN() {
        lock.lock()
        _pin = SessionStore.generatePIN()
        failures = 0
        lockedUntil = nil
        lock.unlock()
    }

    enum PairResult {
        case success(token: String)
        case wrongPIN
        case throttled(retryAfter: TimeInterval)
    }

    /// Exchange a PIN for a session token. Rate-limited with exponential backoff.
    func pair(pin candidate: String, label: String) -> PairResult {
        lock.lock()

        if let until = lockedUntil, until > Date() {
            let wait = until.timeIntervalSinceNow
            lock.unlock()
            return .throttled(retryAfter: wait)
        }

        guard SessionStore.constantTimeEqual(candidate, _pin) else {
            failures += 1
            if failures >= SessionStore.maxFreeAttempts {
                let over = failures - SessionStore.maxFreeAttempts
                let delay = min(SessionStore.baseLockout * pow(2, Double(over)), SessionStore.maxLockout)
                lockedUntil = Date().addingTimeInterval(delay)
            }
            lock.unlock()
            return .wrongPIN
        }

        failures = 0
        lockedUntil = nil

        let token = SessionStore.randomToken()
        let device = Device(hash: SessionStore.hash(token), label: label, created: Date())
        devices.append(device)
        let snapshot = devices
        lock.unlock()

        persist(snapshot)
        return .success(token: token)
    }

    /// 256 bits of CSPRNG output, hex encoded.
    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verification

    /// True if the presented token matches a paired device.
    func isAuthorized(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let presented = SessionStore.hash(token)
        lock.lock(); let known = devices; lock.unlock()
        // Constant-time per candidate. The set is tiny (paired phones), so the
        // linear scan is irrelevant to performance.
        return known.contains { SessionStore.constantTimeEqual(presented, $0.hash) }
    }

    var pairedDeviceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return devices.count
    }

    /// Forget every paired device. Existing sockets must be closed by the caller —
    /// revocation only invalidates future authentication.
    func revokeAll() {
        lock.lock(); devices = []; lock.unlock()
        persist([])
    }

    // MARK: - Persistence

    private func load() -> [Device] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return [] }
        return decoded.devices
    }

    private func persist(_ snapshot: [Device]) {
        guard let data = try? JSONEncoder().encode(Persisted(devices: snapshot)) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // An atomic write replaces the file via a temporary one, which does
            // not inherit the old mode — so the mode is applied after, not
            // before, or it would be silently discarded.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[SessionStore] could not persist session file: %@", error.localizedDescription)
        }
    }

    // MARK: - Utilities

    /// Length-independent only in the equal-length case, which is all that is
    /// needed here: both operands are fixed-width (6-digit PIN, 64-char hex hash).
    static func constantTimeEqual(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< y.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
