import Foundation
import ZoopShared

public enum DemoResearch {
    public static func plan(request: String, context: CompanionTask? = nil) -> CompanionTask {
        let request = [context?.request, request].compactMap { $0 }.joined(separator: " ")
        let input = request.lowercased()
        let kind: ResearchKind
        if ["keyboard", "switch", "keycap"].contains(where: input.contains) { kind = .keyboards }
        else if ["weekend", "getaway", "travel", "trip", "hotel"].contains(where: input.contains) { kind = .getaway }
        else { kind = .tools }
        let id = UUID()
        let suffix = id.uuidString.prefix(6).lowercased()
        switch kind {
        case .keyboards:
            return CompanionTask(id: id, request: request, title: "Find your next keyboard", domain: "rtings.com/keyboards",
                fileName: "mechanical_keyboards-\(suffix).md", steps: [
                    "Explore RTINGS reviews and shortlist three keyboards",
                    "Compare typing feel, latency, and prices",
                    "Save a tidy comparison in your exports folder",
                ], kind: kind)
        case .getaway:
            return CompanionTask(id: id, request: request, title: "A little weekend escape", domain: "travel.google.com",
                fileName: "weekend_getaway-\(suffix).md", steps: [
                    "Explore three peaceful stays near San Francisco",
                    "Compare location, nightly rates, and the little extras",
                    "Save your shortlist and a simple weekend itinerary",
                ], kind: kind)
        case .tools:
            return CompanionTask(id: id, request: request, title: "Research your idea", domain: "notion.so · linear.app · readwise.io",
                fileName: "research_notes-\(suffix).md", steps: [
                    "Explore the tools and gather the useful details",
                    "Compare features, pricing, and the best fit",
                    "Bring the findings together in a concise report",
                ], kind: kind)
        }
    }

    public static func rows(for kind: ResearchKind) -> [ComparisonRow] {
        switch kind {
        case .keyboards: [
            .init(name: "Keychron Q1 Max", detail: "75% · Gateron Jupiter Brown", metric: "3.2 ms", price: "$179"),
            .init(name: "NuPhy Air75 V2", detail: "75% · Low profile · Wireless", metric: "5.1 ms", price: "$119"),
            .init(name: "Wooting 60HE+", detail: "60% · Hall effect · Wired", metric: "0.8 ms", price: "$175"),
        ]
        case .getaway: [
            .init(name: "A cabin in Point Reyes", detail: "Coastal trails · 1.5 hours away", metric: "4.9 / 5", price: "$189"),
            .init(name: "A hideaway in Mendocino", detail: "Ocean views · 3 hours away", metric: "4.8 / 5", price: "$225"),
            .init(name: "A cottage in Sonoma", detail: "Garden terrace · 1 hour away", metric: "4.7 / 5", price: "$165"),
        ]
        case .tools: [
            .init(name: "Notion", detail: "A home for notes, docs, and projects", metric: "9.1 / 10", price: "$10"),
            .init(name: "Linear", detail: "Keep projects moving with less effort", metric: "9.4 / 10", price: "$8"),
            .init(name: "Readwise Reader", detail: "Save the good stuff. Find it again.", metric: "8.8 / 10", price: "$10"),
        ]
        }
    }

    public static func report(for task: CompanionTask) -> String {
        let rows = rows(for: task.kind).map { "| \($0.name) | \($0.detail) | \($0.metric) | \($0.price) |" }.joined(separator: "\n")
        return """
        # \(task.title)

        > Zoop native UI preview. All listings, scores, and prices are illustrative sample data, not live research.

        ## Your request
        \(task.request)

        ## Comparison
        | Option | Details | Metric | Sample price |
        | --- | --- | --- | --- |
        \(rows)

        Prepared in Zoop’s simulated isolated desk. Verify current details before deciding.
        """
    }
}
