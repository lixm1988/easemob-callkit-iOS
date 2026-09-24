import Foundation

@objc public protocol TimerServiceListener: NSObjectProtocol {
    func timeChanged(_ timerIdentify: String, interval: UInt)
}

@objc public protocol TimerService: NSObjectProtocol {
    func replaceTimer(_ listener: TimerServiceListener, timerIdentify: String)
    func registerListener(_ listener: TimerServiceListener, timerIdentify: String)
    func removeListener(_ listener: TimerServiceListener, timerIdentify: String)
}

private final class TimerListener: NSObject, TimerServiceListener {
    func timeChanged(_ timerIdentify: String, interval: UInt) {}
}

@main
enum GlobalTimerManagerRegistrationTests {
    static func main() {
        let timerManager = GlobalTimerManager.shared
        timerManager.invalidate()
        defer { timerManager.invalidate() }

        let timerKey = "call-channel-answering-timer"
        let managerListener = TimerListener()
        let controllerListener = TimerListener()

        timerManager.registerListener(managerListener, timerIdentify: timerKey)
        guard let initialStartTime = timerManager.timerCache[timerKey] else {
            preconditionFailure("Expected the first listener to create the timer")
        }

        Thread.sleep(forTimeInterval: 0.02)
        timerManager.registerListener(controllerListener, timerIdentify: timerKey)
        precondition(
            timerManager.timerCache[timerKey] == initialStartTime,
            "A later listener must preserve the existing timer start time"
        )

        let secondTimerKey = "call-another-channel-answering-timer"
        Thread.sleep(forTimeInterval: 0.02)
        timerManager.registerListener(managerListener, timerIdentify: secondTimerKey)
        guard let secondStartTime = timerManager.timerCache[secondTimerKey] else {
            preconditionFailure("Expected a different key to create an independent timer")
        }
        precondition(secondStartTime > initialStartTime)

        print("GlobalTimerManagerRegistrationTests passed")
    }
}
