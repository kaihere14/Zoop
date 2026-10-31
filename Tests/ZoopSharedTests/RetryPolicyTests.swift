import Darwin
import Foundation
import Testing
@testable import ZoopShared

@Suite struct RetryPolicyTests {
    @Test func defaultsAreThreeRetriesWithDoublingDelays() {
        let policy = RetryPolicy()
        #expect(policy.maxAttempts == 4)
        #expect(policy.delay(beforeRetry: 1, random: 0) == .milliseconds(500))
        #expect(policy.delay(beforeRetry: 2, random: 0) == .seconds(1))
        #expect(policy.delay(beforeRetry: 3, random: 0) == .seconds(2))
    }

    @Test func delayIsCapped() {
        let policy = RetryPolicy(maxRetries: 10, maxDelay: .seconds(3))
        #expect(policy.delay(beforeRetry: 9, random: 0) == .seconds(3))
    }

    @Test func jitterStaysWithinBounds() {
        let policy = RetryPolicy(jitter: 0.2)
        #expect(policy.delay(beforeRetry: 1, random: 1) == .milliseconds(600))
        #expect(policy.delay(beforeRetry: 1, random: -1) == .milliseconds(400))
        for _ in 0..<100 {
            let delay = policy.delay(beforeRetry: 2)
            #expect(delay >= .milliseconds(800) && delay <= .milliseconds(1200))
        }
    }
}

@Suite struct BridgeErrorTests {
    @Test func connectErrorsAreClassified() {
        let path = "/tmp/x.sock"
        #expect(BridgeError(connecting: SocketError("connect", code: ENOENT), path: path).isRetryable)
        #expect(BridgeError(connecting: SocketError("connect", code: ECONNREFUSED), path: path).isRetryable)
        #expect(!BridgeError(connecting: SocketError("connect", code: EACCES), path: path).isRetryable)
        #expect(!BridgeError(connecting: SocketError("connect", code: ENAMETOOLONG), path: path).isRetryable)
    }

    @Test func onlyTransientErrorsAreRetryable() {
        #expect(BridgeError.timedOut(command: "ping", seconds: 2).isRetryable)
        #expect(BridgeError.connectionLost("x").isRetryable)
        #expect(!BridgeError.unauthorized("x").isRetryable)
        #expect(!BridgeError.versionMismatch(client: 1, helper: 2).isRetryable)
        #expect(!BridgeError.helperFailure(HelperFailure(.permissionDenied, "x")).isRetryable)
    }

    @Test func exhaustedMessageExplainsTheCause() {
        let error = BridgeError.retriesExhausted(attempts: 4, last: .helperUnavailable("no socket"))
        #expect(error.userMessage.contains("4 attempts"))
        #expect(error.userMessage.contains("agent user is logged in"))
    }
}
