import Foundation

/// Maps `items` with at most `limit` operations in flight, keeping input order. Used to run many short git
/// commands in parallel without starting hundreds of processes at once.
public func boundedConcurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    _ transform: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    precondition(limit > 0, "limit must be positive")
    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        var next = 0
        // Prime the group, then start one new task each time one finishes.
        while next < min(limit, items.count) {
            let index = next
            group.addTask { (index, try await transform(items[index])) }
            next += 1
        }
        while let (index, output) = try await group.next() {
            results[index] = output
            if next < items.count {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
        }
        // Every index was filled above (a failure throws instead), so nothing is dropped here.
        return results.compactMap { $0 }
    }
}
