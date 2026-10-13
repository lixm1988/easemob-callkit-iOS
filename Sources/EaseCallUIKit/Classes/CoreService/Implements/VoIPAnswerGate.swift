final class VoIPAnswerGate {
    private(set) var pendingCallID: String?
    private var invitationCallIDs: Set<String> = []
    private var accepting = false
    private var fulfilledCallID: String?

    func invitationReceived(callID: String) {
        invitationCallIDs.insert(callID)
    }

    func begin(callID: String) {
        pendingCallID = callID
        accepting = false
    }

    func beginAcceptIfReady(callID: String, isConnected: Bool, isRinging: Bool) -> Bool {
        guard pendingCallID == callID, invitationCallIDs.contains(callID),
              isConnected, isRinging, !accepting else { return false }
        accepting = true
        return true
    }

    func end(callID: String) {
        invitationCallIDs.remove(callID)
        if fulfilledCallID == callID { fulfilledCallID = nil }
        if pendingCallID == callID {
            pendingCallID = nil
            accepting = false
        }
    }

    func markFulfilled(callID: String) {
        fulfilledCallID = callID
    }

    func isFulfilled(callID: String) -> Bool {
        fulfilledCallID == callID
    }

    func reset() {
        pendingCallID = nil
        invitationCallIDs.removeAll()
        accepting = false
        fulfilledCallID = nil
    }
}
