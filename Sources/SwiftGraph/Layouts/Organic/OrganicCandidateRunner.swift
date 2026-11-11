import Foundation

/// Runs organic quality candidates on all cores and returns their results in candidate order.
///
/// Workers run on GCD threads, where task-locals and task cancellation are not inherited. Progress is re-bound from a
/// captured context, and cancellation reaches them through `cancellation`, which the calling thread raises while it
/// waits. Code on the candidate path therefore checks `checkCancellation()` rather than `Task.checkCancellation()`.
enum OrganicCandidateRunner {
    // MARK: - Cancellation

    @TaskLocal static var cancellation: RoutingCancellation?

    static func checkCancellation() throws {
        try Task.checkCancellation()
        try cancellation?.check()
    }

    // MARK: - Running

    /// How often the waiting caller looks for task cancellation to forward to the workers.
    private static let cancellationPollInterval = DispatchTimeInterval.milliseconds(10)

    /// `body(index)` for every index in `0..<count`, concurrently, as child stages named by `stage`. The results do
    /// not depend on scheduling: each call must use only its own inputs. When any call fails, the remaining ones are
    /// cancelled, and the lowest-indexed failure other than cancellation is rethrown.
    static func map<T: Sendable>(
        _ count: Int,
        stage: @escaping @Sendable (Int) -> String,
        _ body: @escaping @Sendable (Int) throws -> T
    ) throws -> [T] {
        let lanes = ProcessInfo.processInfo.activeProcessorCount
        guard count > 1, lanes > 1 else {
            return try (0..<count).map { index in
                try LayoutStageScope.run(stage(index), part: index, of: count) { try body(index) }
            }
        }
        // Candidates start roughly in index order, `lanes` at a time, so each wave shares one slice of progress.
        let waves = (count + lanes - 1) / lanes
        let outer = cancellation
        let token = RoutingCancellation()
        let progress = LayoutStageScope.capture()
        let slots = ResultSlots<T>(count: count)
        let finished = DispatchSemaphore(value: 0)
        let qos = DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .default, relativePriority: 0)
        // A serial queue is overcommitting: it gets a thread even when every pool thread is blocked, as callers on the
        // cooperative pool are here. That thread joins `concurrentPerform`, so the work progresses with no other help.
        // A global queue is not: with all its threads waiting below, its block may never start.
        DispatchQueue(label: "SwiftGraph.organic.candidates", qos: qos).async {
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let wave = Double(index / lanes)
                let result = Result { () throws -> T in
                    try token.check()
                    return try progress.bind {
                        try $cancellation.withValue(token) {
                            try LayoutStageScope.run(
                                stage(index),
                                from: wave / Double(waves),
                                to: (wave + 1) / Double(waves)
                            ) {
                                try body(index)
                            }
                        }
                    }
                }
                if case .failure = result { token.cancel() }
                slots.store(result, at: index)
            }
            finished.signal()
        }
        while finished.wait(timeout: .now() + cancellationPollInterval) == .timedOut {
            if Task.isCancelled || outer?.isCancelled == true { token.cancel() }
        }
        try checkCancellation()
        return try slots.values()
    }
}

// MARK: - Result slots

/// One result per index, written once by its own worker.
private final class ResultSlots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<T, any Error>?]

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func store(_ result: Result<T, any Error>, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
    }

    /// The values in index order, or the first failure that is not a cancellation.
    func values() throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var values: [T] = []
        var wasCancelled = false
        for result in results {
            switch result {
            case .success(let value)?:
                values.append(value)
            case .failure(let error)? where !(error is CancellationError):
                throw error
            case .failure?, nil:
                wasCancelled = true
            }
        }
        if wasCancelled { throw CancellationError() }
        return values
    }
}
