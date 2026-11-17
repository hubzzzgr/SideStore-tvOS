import XCTest
@testable import TVPairCore

final class TVOperationCoordinatorTests: XCTestCase {
    func testSwitchCancelsEveryAdmittedOperationAndRejectsQueuedOldWork() async throws {
        let gate = TVOperationCoordinator()
        let oldGeneration = gate.generation
        let cancelled = expectation(description: "Old operations cancelled")
        cancelled.expectedFulfillmentCount = 2
        let first = try gate.enter(generation: oldGeneration) { cancelled.fulfill() }
        let second = try gate.enter(generation: oldGeneration) { cancelled.fulfill() }
        gate.beginTransition()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertThrowsError(try gate.enter(generation: oldGeneration) {})
        XCTAssertThrowsError(try gate.enter(generation: gate.generation) {})
        gate.leave(first)
        XCTAssertTrue(gate.hasActiveOperations)
        gate.leave(second)
        await gate.drain()
        gate.endTransition()
        XCTAssertThrowsError(try gate.enter(generation: oldGeneration) {})
        let current = try gate.enter(generation: gate.generation) {}
        gate.leave(current)
    }

    func testDrainDoesNotCompleteUntilCleanupHasLeftTheGate() async throws {
        let gate = TVOperationCoordinator()
        let id = try gate.enter(generation: gate.generation) {}
        defer { gate.leave(id) }
        gate.beginTransition()
        let completion = DrainCompletion()
        let waiting = Task { await gate.drain(); await completion.finish() }
        // The gate remains occupied even after cancellation was requested.
        XCTAssertTrue(gate.hasActiveOperations)
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeCleanup = await completion.finished
        XCTAssertFalse(beforeCleanup)
        gate.leave(id)
        await waiting.value
        let afterCleanup = await completion.finished
        XCTAssertTrue(afterCleanup)
        gate.endTransition()
        XCTAssertFalse(gate.hasActiveOperations)
    }

    func testRepeatedTransitionsNeverAdmitAnEarlierGeneration() async throws {
        let gate = TVOperationCoordinator()
        let original = gate.generation
        for _ in 0..<10 { gate.beginTransition(); await gate.drain(); gate.endTransition() }
        XCTAssertThrowsError(try gate.enter(generation: original) {})
        let current = try gate.enter(generation: gate.generation) {}
        gate.leave(current)
    }
}

private actor DrainCompletion {
    var finished = false
    func finish() { finished = true }
}
