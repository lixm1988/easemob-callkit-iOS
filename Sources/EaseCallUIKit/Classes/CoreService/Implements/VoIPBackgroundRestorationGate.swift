import Foundation

final class VoIPBackgroundRestorationGate {
    private var pendingCallID: String?

    func begin(callID: String) {
        pendingCallID = callID
    }

    func shouldDefer(callID: String) -> Bool {
        pendingCallID == callID
    }

    func finish(callID: String, currentCallID: String?, isBackground: Bool) -> Bool {
        guard pendingCallID == callID else { return false }
        pendingCallID = nil
        return isBackground && (currentCallID == nil || currentCallID?.isEmpty == true)
    }
}
