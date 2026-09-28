import Foundation

// Test doubles for the RTC account and UIKit boundaries; the runner injects the SDK implementation.
enum LogLevel { case debug }
func consoleLogInfo(_ message: String, type: LogLevel) {}
final class ChatClient {
    static let instance = ChatClient()
    static func shared() -> ChatClient { instance }
    var currentUsername: String? = "alice"
}
final class AgoraUserInfo {
    var userAccount: String?
    init(_ account: String?) { userAccount = account }
}
final class AgoraRtcEngineKit {
    var accounts: [UInt: String] = [:]
    var queries: [UInt] = []
    func getUserInfo(byUid uid: UInt, withError: Int?) -> AgoraUserInfo? {
        queries.append(uid)
        return accounts[uid].map(AgoraUserInfo.init)
    }
}
final class CallStreamItem {
    var userId: String
    var uid: UInt32 = 0
    var waiting = true
    var audioMuted = false
    var videoMuted = true
    var networkStatus = 0
    init(_ userId: String) { self.userId = userId }
}
final class CallStreamView {
    var item: CallStreamItem
    var removed = false
    init(_ item: CallStreamItem) { self.item = item }
    func updateItem(_ item: CallStreamItem) { self.item = item }
    func removeFromSuperview() { removed = true }
}
@objc enum CallType: Int { case groupCall, singleVideo }
final class CallInfo {
    var type = CallType.groupCall
    var callId = "call"
    var channelName = "channel-call"
}
enum AgoraUserOfflineReason: Int { case quit, dropped, becomeAudience }
enum CallEndReason { case hangup, abnormalEnd }
@objc protocol TestListener {
    @objc optional func remoteUserDidJoined(userId: String, channelName: String, type: CallType)
    @objc optional func remoteUserDidLeft(userId: String, channelName: String, type: CallType)
}
final class Listener: NSObject, TestListener {
    var joined: [String] = []
    var left: [String] = []
    func remoteUserDidJoined(userId: String, channelName: String, type: CallType) { joined.append(userId) }
    func remoteUserDidLeft(userId: String, channelName: String, type: CallType) { left.append(userId) }
}
final class Listeners { var allObjects: [TestListener] = [] }
final class Throttler { func clearUserPendings(with uid: UInt) {} }
class UIViewController { static var currentController: UIViewController? }
final class CallMultiViewController: UIViewController {
    let callView = MultiCallView()
}
final class MultiCallView {
    var removedUsers: [String] = []
    func updateWithItems(_ removedUsers: [String]) { self.removedUsers = removedUsers }
}
final class CallKitManager {
    var itemsCache: [String: CallStreamItem] = [:]
    var canvasCache: [String: CallStreamView] = [:]
    var callInfo: CallInfo? = CallInfo()
    var callVC: UIViewController?
    let listeners = Listeners()
    let rtcThrottler = Throttler()
    func terminateCall() {}
    func updateCallEndReason(_ reason: CallEndReason) {}
    var profiles: [String] = []
    var remoteVideoSetups: [String] = []
    func performRTCUIUpdate(_ update: () -> Void) { update() }
    func setupRemoteVideoView(userId: String, uid: UInt) { remoteVideoSetups.append(userId) }
    func providerFetchUsersInfo(_ accounts: [String]) { profiles += accounts }
    // IMPLEMENTATION
}

@main
enum RTCUserAccountTests {
    static func main() {
        let manager = CallKitManager()
        let engine = AgoraRtcEngineKit()
        engine.accounts[42] = "bob"
        precondition(manager.rtcUserAccount(for: 42, engine: engine) == "bob")
        engine.accounts[42] = "charlie"
        precondition(manager.rtcUserAccount(for: 42, engine: engine) == "charlie", "Always use RTC's current account; no separate mapping cache")
        precondition(manager.rtcUserAccount(for: 0, engine: engine) == "alice")
        precondition(!engine.queries.contains(0), "UID 0 means the local user in quality and volume callbacks")
        precondition(manager.rtcUserAccount(for: 99, engine: engine) == nil)
        engine.accounts[99] = ""
        precondition(manager.rtcUserAccount(for: 99, engine: engine) == nil)
        ChatClient.shared().currentUsername = ""
        precondition(manager.rtcUserAccount(for: 0, engine: engine) == nil)
        ChatClient.shared().currentUsername = "alice"

        // A late SDK account update must merge the temporary stream into an invited participant.
        let invited = CallStreamItem("bob")
        let invitedView = CallStreamView(invited)
        let temporary = CallStreamItem("uid-42")
        temporary.uid = 42
        temporary.waiting = false
        temporary.videoMuted = false
        temporary.audioMuted = true
        let temporaryView = CallStreamView(temporary)
        manager.itemsCache = ["bob": invited, "uid-42": temporary]
        manager.canvasCache = ["bob": invitedView, "uid-42": temporaryView]
        engine.accounts[42] = "bob"
        let controller = CallMultiViewController()
        manager.callVC = controller
        manager.rtcEngine(engine, didUserInfoUpdatedWithUserId: 42, userInfo: AgoraUserInfo("bob"))
        precondition(manager.itemsCache.count == 1 && manager.canvasCache.count == 1)
        precondition(manager.itemsCache["bob"] === invited && manager.canvasCache["bob"] === invitedView)
        precondition(temporaryView.removed && !invited.waiting && invited.uid == 42)
        precondition(invited.audioMuted && !invited.videoMuted, "Preserve media state received before the account")
        precondition(controller.callView.removedUsers == ["uid-42"])
        precondition(manager.remoteVideoSetups == ["bob"] && manager.profiles == ["bob"])

        // With no invitation tile, migrate the temporary view itself.
        let other = CallStreamItem("uid-77")
        other.uid = 77
        let otherView = CallStreamView(other)
        manager.itemsCache["uid-77"] = other
        manager.canvasCache["uid-77"] = otherView
        manager.promotePlaceholderIfNeeded(uid: 77, realUserId: "dave")
        precondition(manager.itemsCache["dave"] === other && manager.canvasCache["dave"] === otherView)
        precondition(other.userId == "dave" && manager.itemsCache["uid-77"] == nil)
        let listener = Listener()
        manager.listeners.allObjects = [listener]
        let unresolved = CallStreamItem("uid-88")
        unresolved.uid = 88
        manager.itemsCache["uid-88"] = unresolved
        manager.canvasCache["uid-88"] = CallStreamView(unresolved)
        engine.accounts[88] = "eve"
        manager.rtcEngine(engine, didUserInfoUpdatedWithUserId: 88, userInfo: AgoraUserInfo("eve"))
        manager.rtcEngine(engine, didUserInfoUpdatedWithUserId: 88, userInfo: AgoraUserInfo("eve"))
        precondition(listener.joined == ["eve"], "Late account information must deliver exactly one join notification")

        // The SDK can discard account information before the departure callback.
        engine.accounts.removeValue(forKey: 42)
        manager.rtcEngine(engine, didOfflineOfUid: 42, reason: .quit)
        precondition(manager.itemsCache["bob"] == nil && manager.canvasCache["bob"] == nil)
        precondition(listener.left == ["bob"], "Cleanup may use the active stream UID if the SDK has already removed account information")
        precondition(controller.callView.removedUsers == ["bob"])
        print("RTCUserAccountTests passed")
    }
}
