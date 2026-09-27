import Foundation
import Observation

/// Refreshes a value off the main thread at a fixed interval while a view is on screen.
/// Use from `.task`: the loop ends when the view goes away.
@Observable
final class Poll<Value: Sendable> {
    private(set) var value: Value?

    func run(every interval: Duration, _ fetch: @escaping @Sendable () -> Value?) async {
        value = nil
        while !Task.isCancelled {
            let next = await Task.detached(priority: .userInitiated) { fetch() }.value
            if Task.isCancelled { break }
            value = next
            try? await Task.sleep(for: interval)
        }
    }
}
