import Foundation

@main
enum CallParticipantRemovalPolicyTests {
    static func main() {
        let cached = Set(["alice", "bob", "charlie"])

        let busyOnly = CallParticipantRemovalPolicy.usersToRemove(
            cachedUsers: cached,
            currentUser: "alice",
            reportedStates: ["bob": 6]
        )
        precondition(busyOnly == Set(["bob"]), "A busy update must keep Charlie's active view")

        let fullState = CallParticipantRemovalPolicy.usersToRemove(
            cachedUsers: cached,
            currentUser: "alice",
            reportedStates: ["alice": 3, "bob": 6, "charlie": 3]
        )
        precondition(fullState == Set(["bob"]))

        let missingMember = CallParticipantRemovalPolicy.usersToRemove(
            cachedUsers: cached,
            currentUser: "alice",
            reportedStates: ["bob": 3]
        )
        precondition(missingMember.isEmpty)
        let timeoutOnly = CallParticipantRemovalPolicy.usersToRemove(
            cachedUsers: cached,
            currentUser: "alice",
            reportedStates: ["bob": 7]
        )
        precondition(timeoutOnly == Set(["bob"]), "A timed-out invitee must be removed without removing active members")
        let mixedTimeout = CallParticipantRemovalPolicy.usersToRemove(
            cachedUsers: cached,
            currentUser: "alice",
            reportedStates: ["alice": 7, "bob": 7, "charlie": 3]
        )
        precondition(mixedTimeout == Set(["bob"]), "Keep the local view and accepted participants")
        precondition(CallParticipantRemovalPolicy.isTerminal(7))
        print("CallParticipantRemovalPolicyTests passed")
    }
}
