import Foundation
import ZoopShared

public struct PlannedTask: Sendable {
    public let plan: TaskPlan
    public let modelCalls: Int
    public let usage: ModelUsage
}
