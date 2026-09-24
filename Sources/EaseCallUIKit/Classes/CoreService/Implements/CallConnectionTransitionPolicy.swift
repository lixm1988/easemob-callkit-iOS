import Foundation

enum CallConnectionTransitionPolicy {
    static func shouldEnterAnswering(isAnswering: Bool, hasAcceptedParticipant: Bool) -> Bool {
        !isAnswering && hasAcceptedParticipant
    }
}
