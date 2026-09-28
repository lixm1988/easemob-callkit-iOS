import Foundation

@main
enum LatestFrameMailboxTests {
    static func main() {
        let mailbox = LatestFrameMailbox<Int>()
        var rendered: [Int] = []

        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for frame in 1...100 {
                mailbox.submit(frame) { value in
                    precondition(Thread.isMainThread)
                    rendered.append(value)
                }
            }
            submitted.signal()
        }
        precondition(submitted.wait(timeout: .now() + 1) == .success)

        let deadline = Date().addingTimeInterval(1)
        while rendered.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(rendered == [100], "Expected only the newest queued frame, got \(rendered)")
        print("LatestFrameMailboxTests passed")
    }
}
