import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

@Suite struct BrowserSessionTests {
    @Test func mcpResultsBecomeToolResultsWithShortenedTextAndImages() {
        let long = String(repeating: "x", count: BrowserSession.maxText + 50)
        let png = Data([0x89, 0x50]).base64EncodedString()
        let result = BrowserSession.toolResult("browser_snapshot", ["content": [
            ["type": "text", "text": .string(long)], ["type": "image", "data": .string(png), "mimeType": "image/jpeg"]]])
        #expect(!result.isError)
        #expect(result.content["result"]?.stringValue?.count == BrowserSession.maxText)
        #expect(result.content["next"]?.stringValue?.contains("browser_find") == true)
        #expect(result.image?.mediaType == "image/jpeg")
        let failed = BrowserSession.toolResult("browser_click", ["isError": true, "content": [["type": "text", "text": "Ref not found"]]])
        #expect(failed.isError && failed.content["error"] == "browser_error")
    }

    @Test func onlyPageChangingBrowserToolsCountAsActions() {
        #expect(BrowserToolRunner.isAction("browser_click"))
        #expect(!BrowserToolRunner.isAction("browser_find"))
        #expect(!BrowserToolRunner.isAction("browser_run_code_unsafe"))
        #expect(BrowserSession.cleanSchema(["$schema": "x", "type": "object"]) == ["type": "object"])
    }

    /// Live: launches headless Chrome through Playwright MCP. Run with ZOOP_LIVE_BROWSER=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOOP_LIVE_BROWSER"] == "1"))
    func liveBrowserReadsApplesPrice() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("zoop-browser-test-\(UUID().uuidString)")
        let browser = BrowserSession(support: support)
        let tools = await browser.modelTools()
        #expect(tools.map(\.name).contains("browser_find"))
        let opened = await browser.call("browser_navigate", argumentsJSON: #"{"url":"https://www.apple.com/in/shop/buy-mac/macbook-air"}"#)
        #expect(!opened.isError)
        let found = await browser.call("browser_find", argumentsJSON: #"{"text":"₹"}"#)
        #expect(found.content["result"]?.stringValue?.contains("₹149900") == true)
        #expect(await browser.isActive)
        #expect(await browser.previewFrame() != nil)
        await browser.shutdown()
        try? FileManager.default.removeItem(at: support)
    }
}
