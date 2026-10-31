import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

@Test func plansUseTheRightScenarioAndStayPending() {
    let keyboards = DemoResearch.plan(request: "Compare quiet mechanical keyboards under $150")
    let trip = DemoResearch.plan(request: "Plan a weekend getaway")
    #expect(keyboards.kind == .keyboards)
    #expect(keyboards.phase == .pending)
    #expect(keyboards.progress == 0)
    #expect(trip.kind == .getaway)
    #expect(keyboards.steps.count == 3)
}

@Test func refinementsKeepContextAndExportsAreUnique() {
    let first = DemoResearch.plan(request: "Compare mechanical keyboards")
    let revised = DemoResearch.plan(request: "Only include quiet switches", context: first)
    #expect(revised.request.contains(first.request))
    #expect(revised.request.contains("Only include quiet switches"))
    #expect(revised.kind == .keyboards)
    #expect(first.id != revised.id)
    #expect(first.fileName != revised.fileName)
    #expect(!revised.fileName.contains("/"))
}

@Test func exportsClearlyIdentifySampleDataAndKeepTheRequest() {
    let task = DemoResearch.plan(request: "Compare design tools")
    let report = DemoResearch.report(for: task)
    #expect(report.contains("illustrative sample data"))
    #expect(report.contains(task.request))
    #expect(report.contains("Notion"))
    #expect(report.contains("| Option | Details |"))
}
