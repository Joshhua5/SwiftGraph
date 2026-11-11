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

    /// `body(index)` for indices in `0..<count`, concurrently, as child stages named by `stage`. The results do not
    /// depend on scheduling: each call must use only its own inputs.
    ///
    /// The run ends at the first index, in index order, whose result makes `stopsAfter` true or whose call fails.
    /// `stopsAfter` is called once per index, in index order, with the results from index 0 to that index. Calls
    /// with a higher index than the end are cancelled or never started, and calls below it always run to completion,
    /// so the outcome is the one a sequential loop would give: the results up to and including the stopping index,
    /// or the lowest-indexed failure other than cancellation.
    static func map<T: Sendable>(
        _ count: Int,
        stage: @escaping @Sendable (Int) -> String,
        stopsAfter: @escaping @Sendable (ArraySlice<T>) -> Bool = { _ in false },
        _ body: @escaping @Sendable (Int) throws -> T
    ) throws -> [T] {
        let lanes = ProcessInfo.processInfo.activeProcessorCount
        guard count > 1, lanes > 1 else {
            var results: [T] = []
            for index in 0..<count {
                results.append(try LayoutStageScope.run(stage(index), part: index, of: count) { try body(index) })
                if stopsAfter(results[...]) { break }
            }
            return results
        }
        // Candidates start roughly in index order, `lanes` at a time, so each wave shares one slice of progress.
        let waves = (count + lanes - 1) / lanes
        let outer = cancellation
        // One token per index, so a stop or failure can cancel the calls above it and leave the ones below running.
        let tokens = (0..<count).map { _ in RoutingCancellation() }
        let progress = LayoutStageScope.capture()
        let slots = ResultSlots<T>(count: count, stopsAfter: stopsAfter)
        let finished = DispatchSemaphore(value: 0)
        let qos = DispatchQoS(
            qosClass: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .default,
            relativePriority: 0
        )
        // A serial queue is overcommitting: it gets a thread even when every pool thread is blocked, as callers on the
        // cooperative pool are here. That thread joins `concurrentPerform`, so the work progresses with no other help.
        // A global queue is not: with all its threads waiting below, its block may never start.
        DispatchQueue(label: "SwiftGraph.organic.candidates", qos: qos)
            .async {
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    let wave = Double(index / lanes)
                    let token = tokens[index]
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
                    if let end = slots.store(result, at: index) {
                        for later in tokens[end...] { later.cancel() }
                    }
                }
                finished.signal()
            }
        while finished.wait(timeout: .now() + cancellationPollInterval) == .timedOut {
            if Task.isCancelled || outer?.isCancelled == true {
                for token in tokens { token.cancel() }
            }
        }
        try checkCancellation()
        return try slots.values()
    }
}

// MARK: - Result slots

/// One result per index, written once by its own worker, and the end of the run found by folding them in index order.
private final class ResultSlots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let stopsAfter: @Sendable (ArraySlice<T>) -> Bool
    private var results: [Result<T, any Error>?]
    /// The successful results from index 0 on, in order, each already passed to `stopsAfter`.
    private var settled: [T] = []
    /// Indices from here on are not needed: a lower index stopped the run or failed.
    private var end: Int

    init(count: Int, stopsAfter: @escaping @Sendable (ArraySlice<T>) -> Bool) {
        self.stopsAfter = stopsAfter
        results = Array(repeating: nil, count: count)
        end = count
    }

    /// Stores `result` and returns the new end of the run when it moved, so the caller can cancel the calls from it on.
    func store(_ result: Result<T, any Error>, at index: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
        let previousEnd = end
        if case .failure(let error) = result, !(error is CancellationError) { end = min(end, index + 1) }
        while settled.count < end, case .success(let value)? = results[settled.count] {
            settled.append(value)
            if stopsAfter(settled[...]) { end = settled.count }
        }
        return end < previousEnd ? end : nil
    }

    /// The values up to the end of the run, in index order, or the first failure that is not a cancellation.
    func values() throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var values: [T] = []
        var wasCancelled = false
        for result in results.prefix(end) {
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
