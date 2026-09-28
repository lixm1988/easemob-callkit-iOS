import Foundation

enum GroupInviteTimeoutPolicy {
    static func usersToUnmask(timerIdentifier: String, callID: String,
                              waitingUsers: Set<String>) -> [String] {
        let prefix = "call-\(callID) users:"
        let suffix = "-start-timer"
        guard timerIdentifier.hasPrefix(prefix), timerIdentifier.hasSuffix(suffix) else { return [] }
        let users = timerIdentifier.dropFirst(prefix.count).dropLast(suffix.count)
        return users.split(separator: ",").map(String.init).filter { waitingUsers.contains($0) }
    }
}
