enum CallInvitationPolicy {
    enum Action {
        case receive
        case ignoreDuplicate
        case rejectBusy
    }

    static func action(existingCallID: String?, existingCallIsIdle: Bool, incomingCallID: String) -> Action {
        guard let existingCallID, !existingCallIsIdle else { return .receive }
        return existingCallID == incomingCallID ? .ignoreDuplicate : .rejectBusy
    }
}
