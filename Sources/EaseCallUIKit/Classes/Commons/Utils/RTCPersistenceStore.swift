import Foundation

struct RTCCredentialRecord: Codable, Equatable, Sendable {
    let appID: String
    let userID: String
    let uid: UInt32
    let token: String
    let expiration: Int64
    let generation: UInt64
}

final class RTCPersistenceStore {
    private struct Snapshot: Codable {
        var schemaVersion = 2
        var credentials: [String: RTCCredentialRecord] = [:]
    }

    private enum Keys {
        static let snapshot = "com.easemob.callkit.rtc-persistence.v1"
    }

    private let queue = DispatchQueue(label: "com.easemob.callkit.rtc-persistence")
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var snapshot: Snapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.snapshot),
           let decoded = try? decoder.decode(Snapshot.self, from: data),
           decoded.schemaVersion == 2 {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    func loadCredential(appID: String, userID: String) -> RTCCredentialRecord? {
        queue.sync {
            snapshot.credentials[credentialKey(appID: appID, userID: userID)]
        }
    }

    func saveCredential(_ record: RTCCredentialRecord) async {
        await enqueue {
            let key = self.credentialKey(appID: record.appID, userID: record.userID)
            if let current = self.snapshot.credentials[key], current.generation > record.generation { return }
            self.snapshot.credentials[key] = record
            self.persistSnapshot()
        }
    }

    func flush() async { await enqueue {} }

    func clear(appID: String? = nil, userID: String? = nil) async {
        await enqueue {
            if let appID = appID {
                self.snapshot.credentials = self.snapshot.credentials.filter { _, value in
                    value.appID != appID || (userID != nil && value.userID != userID)
                }
            } else {
                self.snapshot = Snapshot()
            }
            self.persistSnapshot()
        }
    }

    private func credentialKey(appID: String, userID: String) -> String {
        Data("\(appID)\u{0}\(userID)".utf8).base64EncodedString()
    }

    private func persistSnapshot() {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot)
    }

    private func enqueue(_ operation: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }
}
