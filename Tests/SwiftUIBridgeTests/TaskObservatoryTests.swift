import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct TaskObservatoryTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func experimentRunsStructuredConcurrencyAndSleep() async throws {
        let projectRoot = repositoryRoot()
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot) + """

        @MainActor
        func runTaskObservatoryIntegrationProbe() async -> String {
            let store = TaskObservatoryStore()
            store.start()

            try? await Task.sleep(for: .milliseconds(320))
            store.cancelBeacon()

            while store.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
            while !store.observerTwo.hasPrefix("Received") {
                try? await Task.sleep(for: .milliseconds(10))
            }

            return store.workers[0].phase + ","
                + store.workers[1].phase + ","
                + store.workers[2].phase + ","
                + store.observerOne + ","
                + store.observerTwo + ","
                + store.groupStatus
        }

        await runTaskObservatoryIntegrationProbe()
        """

        let result = try await Interpreter(registry: ViewRegistry()).runAsync(
            source: source,
            lazyTopLevelGlobals: true
        )

        #expect(result.stringValue == "Completed,Cancelled,Completed,"
            + "Received orbit-10,Received orbit-10,"
            + "TaskGroup reduced 4 values into orbit-10")
    }
}
