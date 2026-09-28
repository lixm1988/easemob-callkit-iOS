import Foundation

@main
enum RTCPersistenceAccountMigrationTests {
    static func main() async {
        let suiteName = "RTCPersistenceAccountMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "com.easemob.callkit.rtc-persistence.v1"
        let credentialKey = Data("app\u{0}alice".utf8).base64EncodedString()
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "credentials": [credentialKey: [
                "appID": "app", "userID": "alice", "uid": 99,
                "token": "numeric-token", "expiration": 0, "generation": 1
            ]],
            "relations": ["app": ["99": "alice"]]
        ]
        defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let store = RTCPersistenceStore(defaults: defaults)
        precondition(store.loadCredential(appID: "app", userID: "alice") == nil,
                     "Do not reuse numeric-UID tokens when migrating to RTC string accounts")
        let accountToken = RTCCredentialRecord(appID: "app", userID: "alice", uid: 0,
                                              token: "account-token", expiration: 0, generation: 2)
        await store.saveCredential(accountToken)
        await store.flush()
        let reloaded = RTCPersistenceStore(defaults: defaults)
        precondition(reloaded.loadCredential(appID: "app", userID: "alice") == accountToken)
        let saved = try! JSONSerialization.jsonObject(with: defaults.data(forKey: key)!) as! [String: Any]
        precondition(saved["relations"] == nil, "Do not persist the removed UID/IM mapping")
        print("RTCPersistenceAccountMigrationTests passed")
    }
}
