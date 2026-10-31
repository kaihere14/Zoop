import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

@Suite struct ProviderSettingsTests {
    @Test func keychainKeyBeatsAPlainFileKeyButNotTheEnvironment() throws {
        let file: JSONValue = ["agents": ["executor": ["provider": "gemini", "model": "m"]], "providers": ["gemini": ["apiKey": "file"]]]
        let keys = InMemoryKeyStore([.gemini: "keychain"])
        #expect(try ModelConfiguration(environment: [:], file: file, keys: keys).endpoint(for: .executor).apiKey == "keychain")
        #expect(try ModelConfiguration(environment: ["GEMINI_API_KEY": "env"], file: file, keys: keys).endpoint(for: .executor).apiKey == "env")
        #expect(try ModelConfiguration(environment: [:], file: file).endpoint(for: .executor).apiKey == "file")
    }

    @Test func activatingPointsEveryAgentAtOneProviderAndKeepsOtherSettings() {
        var config = ZoopConfigFile(["providers": ["ollama": ["baseURL": "http://x/v1/"]],
                                     "agents": ["chat": ["provider": "gemini", "model": "lite"],
                                                "planner": ["provider": "gemini", "model": "flash"],
                                                "executor": ["provider": "gemini", "model": "flash"]]])
        #expect(config.activeProvider == .gemini && config.model(for: .gemini) == "flash")
        config.activate(.groq, model: "llama")
        #expect(config.activeProvider == .groq)
        #expect(config.value["agents"]?["chat"]?["model"]?.stringValue == "llama")
        #expect(config.value["providers"]?["ollama"]?["baseURL"]?.stringValue == "http://x/v1/")
        config.setModel("other", for: .groq)
        #expect(config.value["agents"]?["planner"]?["model"]?.stringValue == "other")
        config.deactivate()
        #expect(config.activeProvider == nil && config.model(for: .groq) == "other")
    }

    @Test func plainKeysAreTakenOutOfTheFile() {
        var config = ZoopConfigFile(["providers": ["gemini": ["apiKey": "secret", "baseURL": "u"]]])
        #expect(config.takePlainKeys() == [.gemini: "secret"])
        #expect(config.value["providers"]?["gemini"]?["apiKey"] == nil)
        #expect(config.value["providers"]?["gemini"]?["baseURL"]?.stringValue == "u")
    }

    @Test func geminiModelNamesAreCleanedAndNonChatModelsHidden() {
        let names = ["models/gemini-3.5-flash", "models/gemini-2.5-flash-preview-tts", "models/gemini-3-pro-image", "models/text-embedding-004"]
        #expect(ModelProvider.gemini.chatModels(from: names) == ["gemini-3.5-flash"])
    }
}
