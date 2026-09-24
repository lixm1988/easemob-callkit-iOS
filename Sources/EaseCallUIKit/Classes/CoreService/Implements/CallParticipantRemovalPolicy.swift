import Foundation

enum CallParticipantRemovalPolicy {
    // EMCallParticipantState: left, rejected, busy, timeout, canceled, hanguped.
    private static let terminalStates: Set<Int> = [4, 5, 6, 7, 8, 9]
    private static let viewRemovalStates: Set<Int> = [4, 5, 6, 8, 9]

    static func isTerminal(_ state: Int) -> Bool {
        terminalStates.contains(state)
    }

    static func usersToRemove(cachedUsers: Set<String>, currentUser: String,
                              reportedStates: [String: Int]) -> Set<String> {
        Set(reportedStates.compactMap { userID, state in
            cachedUsers.contains(userID) && userID != currentUser && viewRemovalStates.contains(state) ? userID : nil
        })
    }
}
