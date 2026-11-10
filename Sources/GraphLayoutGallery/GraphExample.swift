import CoreGraphics
import Foundation
import SwiftGraph
import SwiftGraphUI

/// A named graph plus the SwiftGraph pipeline used to lay it out.
struct GraphExample: Identifiable, Sendable {
    var id: String
    var title: String
    var category: String
    var summary: String

    /// Guidance shown from the sidebar's info button; `nil` hides the button.
    var info: ExampleInfo? = nil
    var makeGraph: @Sendable () throws -> LayoutGraph
    var configure: @Sendable (LayoutBuilder, LayoutBackend) -> Void

    /// Builds the graph and runs the layout pipeline away from the main actor, reporting its progress in order.
    @concurrent func render(
        backend: LayoutBackend = .cpu,
        onProgress: @escaping @MainActor @Sendable (LayoutProgress) -> Void = { _ in }
    ) async throws -> GraphSnapshot {
        try await GraphSnapshot.render(
            backend: backend,
            makeGraph: makeGraph,
            configure: configure,
            onProgress: onProgress
        )
    }

    /// Blocks until `render()` finishes. For previews only: the static preview snapshot is captured
    /// before `.task` work completes. Safe because `render()` is `@concurrent` and never needs the caller's actor.
    func renderSynchronously(
        backend: LayoutBackend = .cpu,
        timeout: TimeInterval = 3.5
    ) -> Result<GraphSnapshot, any Error> {
        final class Box: @unchecked Sendable { var result: Result<GraphSnapshot, any Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.result = .success(try await render(backend: backend)) } catch { box.result = .failure(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(CancellationError())
        }
        return box.result ?? .failure(CancellationError())
    }

    /// Renders multiple examples concurrently for contact-sheet previews.
    static func renderAllSynchronously(
        _ examples: [GraphExample],
        backend: LayoutBackend = .cpu,
        timeout: TimeInterval = 4.0
    ) -> [String: Result<GraphSnapshot, any Error>] {
        final class Box: @unchecked Sendable { var results: [String: Result<GraphSnapshot, any Error>] = [:] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await withTaskGroup(of: (String, Result<GraphSnapshot, any Error>).self) { group in
                for example in examples {
                    group.addTask {
                        do { return (example.id, .success(try await example.render(backend: backend))) } catch {
                            return (example.id, .failure(error))
                        }
                    }
                }
                var collected: [String: Result<GraphSnapshot, any Error>] = [:]
                for await (id, result) in group { collected[id] = result }
                box.results = collected
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
        }
        return box.results
    }
}
