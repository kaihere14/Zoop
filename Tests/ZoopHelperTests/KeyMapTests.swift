import CoreGraphics
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct KeyMapTests {
    @Test func ansiKeysAndAliases() {
        #expect(KeyMap.code(for: "a") == 0)
        #expect(KeyMap.code(for: "L") == 37)
        #expect(KeyMap.code(for: "return") == 36)
        #expect(KeyMap.code(for: "enter") == KeyMap.code(for: "return"))
        #expect(KeyMap.code(for: "tab") == 48)
        #expect(KeyMap.code(for: "space") == 49)
        #expect(KeyMap.code(for: "delete") == 51)
        #expect(KeyMap.code(for: "escape") == 53)
        #expect(KeyMap.code(for: "left") == 123)
        #expect(KeyMap.code(for: "right") == 124)
        #expect(KeyMap.code(for: "down") == 125)
        #expect(KeyMap.code(for: "up") == 126)
        for key in ["home", "end", "pageup", "pagedown", "forwarddelete"] { #expect(KeyMap.code(for: key) != nil) }
        let functionCodes = (1...12).compactMap { KeyMap.code(for: "f\($0)") }
        #expect(functionCodes.count == 12)
        #expect(Set(functionCodes).count == 12)
        #expect(KeyMap.code(for: "f13") == nil)
        #expect(KeyMap.code(for: "💻") == nil)
    }

    @Test func modifiersMatchCoreGraphicsFlags() {
        let flags = KeyMap.flags([.command, .shift, .option, .control, .function])
        #expect(flags == [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
        #expect(KeyMap.flags([]).isEmpty)
    }
}
