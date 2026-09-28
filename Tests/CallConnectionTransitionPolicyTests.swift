import Foundation

@main
enum CallConnectionTransitionPolicyTests {
    static func main() {
        precondition(CallConnectionTransitionPolicy.shouldEnterAnswering(
            isAnswering: false,
            hasAcceptedParticipant: true
        ))
        for _ in 0..<3 {
            precondition(!CallConnectionTransitionPolicy.shouldEnterAnswering(
                isAnswering: true,
                hasAcceptedParticipant: true
            ))
        }
        precondition(!CallConnectionTransitionPolicy.shouldEnterAnswering(
            isAnswering: false,
            hasAcceptedParticipant: false
        ))
        print("CallConnectionTransitionPolicyTests passed")
    }
}
