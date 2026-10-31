import Foundation
import ZoopShared

/// The native UI depends on this boundary, rather than a particular model or desktop helper.
public protocol CompanionService: Sendable {
    func propose(request: String, context: CompanionTask?) async throws -> CompanionTask
    func nextProgressIncrement() async throws -> Int
}

/// A local, deterministic provider for evaluating the native UI. It never controls other apps.
public struct DemoCompanionService: CompanionService {
    public init() {}

    public func propose(request: String, context: CompanionTask?) async throws -> CompanionTask {
        try await Task.sleep(for: .milliseconds(650))
        return DemoResearch.plan(request: request, context: context)
    }

    public func nextProgressIncrement() async throws -> Int {
        try await Task.sleep(for: .milliseconds(1_200))
        return 4
    }
}
