import Foundation

@main
enum GroupInviteTimeoutPolicyTests {
    static func main() {
        let waiting = Set(["bob", "dave"])
        let timer = "call-call123 users:bob,charlie,dave-start-timer"
        precondition(GroupInviteTimeoutPolicy.usersToUnmask(
            timerIdentifier: timer, callID: "call123", waitingUsers: waiting
        ) == ["bob", "dave"])
        precondition(GroupInviteTimeoutPolicy.usersToUnmask(
            timerIdentifier: timer, callID: "anotherCall", waitingUsers: waiting
        ).isEmpty)
        precondition(GroupInviteTimeoutPolicy.usersToUnmask(
            timerIdentifier: "call-call123-start-timer", callID: "call123", waitingUsers: waiting
        ).isEmpty)
        print("GroupInviteTimeoutPolicyTests passed")
    }
}
