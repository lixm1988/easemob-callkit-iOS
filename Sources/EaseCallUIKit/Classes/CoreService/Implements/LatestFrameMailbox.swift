import Foundation

/// Keeps at most one frame waiting for the main thread, replacing stale frames.
final class LatestFrameMailbox<Frame> {
    private let lock = NSLock()
    private var pending: (frame: Frame, consume: (Frame) -> Void)?
    private var scheduled = false

    func submit(_ frame: Frame, consume: @escaping (Frame) -> Void) {
        lock.lock()
        pending = (frame, consume)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let item = pending
            pending = nil
            scheduled = false
            lock.unlock()
            if let item { item.consume(item.frame) }
        }
    }
}
