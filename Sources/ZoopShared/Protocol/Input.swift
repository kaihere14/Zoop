import Foundation

// Types for acting on the agent session: clicks, typing, key combos, scrolling, and the
// accessibility queries that find what to act on.
//
// Coordinates are always display points in global screen space: origin at the top-left of
// the main display, y growing downward. That is the space both Accessibility and Core
// Graphics events use. Screenshots are in pixels; convert with `CaptureMetadata.point`.

public struct Point: Codable, Sendable, Equatable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(String(format: "%.0f", x)), \(String(format: "%.0f", y)))" }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
}

// MARK: - Actions

public enum MouseButton: String, Codable, Sendable {
    case left, right
}

public enum ClickStrategy: String, Codable, Sendable {
    case accessibility, mouse
}

public struct ClickAction: Codable, Sendable, Equatable {
    public var point: Point
    public var button: MouseButton
    /// 1 = single click, 2 = double click.
    public var count: Int
    public var strategy: ClickStrategy
    /// Required for mouse clicks so a stale point cannot target another app.
    public var bundleID: String?

    public init(point: Point, button: MouseButton = .left, count: Int = 1,
                strategy: ClickStrategy = .accessibility, bundleID: String? = nil) {
        self.point = point
        self.button = button
        self.count = count
        self.strategy = strategy
        self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey { case point, button, count, strategy, bundleID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        point = try values.decode(Point.self, forKey: .point)
        button = try values.decode(MouseButton.self, forKey: .button)
        count = try values.decode(Int.self, forKey: .count)
        strategy = try values.decodeIfPresent(ClickStrategy.self, forKey: .strategy) ?? .accessibility
        bundleID = try values.decodeIfPresent(String.self, forKey: .bundleID)
    }
}

/// Writes a text element's value directly through Accessibility instead of typing it.
public struct SetTextAction: Codable, Sendable, Equatable {
    public var text: String
    /// The element to change. `nil` means the focused element.
    public var point: Point?

    public init(text: String, point: Point? = nil) {
        self.text = text
        self.point = point
    }
}

public enum KeyModifier: String, Codable, Sendable, CaseIterable {
    case command, shift, option, control, function
}

/// A key with modifiers, for example Cmd+L or Return.
public struct KeyCombo: Codable, Sendable, Equatable, CustomStringConvertible {
    /// A key name such as "l", "return", "tab", "escape", "left", "f5".
    public var key: String
    public var modifiers: [KeyModifier]

    public init(key: String, modifiers: [KeyModifier] = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses strings like "cmd+shift+l", "return" or "ctrl+a".
    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var modifiers: [KeyModifier] = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "meta": modifiers.append(.command)
            case "shift": modifiers.append(.shift)
            case "opt", "option", "alt": modifiers.append(.option)
            case "ctrl", "control": modifiers.append(.control)
            case "fn", "function": modifiers.append(.function)
            default: return nil
            }
        }
        guard !["cmd", "command", "super", "meta", "shift", "opt", "option", "alt", "ctrl", "control", "fn", "function"].contains(key) else { return nil }
        return KeyCombo(key: key, modifiers: Array(Set(modifiers)).sorted { $0.rawValue < $1.rawValue })
    }

    public var description: String {
        (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
    }
}

public enum ScrollAxis: String, Codable, Sendable, CaseIterable {
    case vertical, horizontal
}

/// Moves a scroll area to an absolute position by writing its scroll bar's AXValue.
/// `fraction` 0 is the top (or left edge) and 1 is the bottom (or right edge).
public struct ScrollToAction: Codable, Sendable, Equatable {
    public var point: Point
    public var axis: ScrollAxis
    public var fraction: Double

    public init(point: Point, axis: ScrollAxis = .vertical, fraction: Double) {
        self.point = point
        self.axis = axis
        self.fraction = fraction
    }
}

public enum InputAction: Codable, Sendable, Equatable {
    case click(ClickAction)
    /// Types text as real keystrokes into the focused element.
    case type(text: String)
    case setText(SetTextAction)
    case key(KeyCombo)
    /// Absolute scroll position through the scroll bar's AXValue.
    case scrollTo(ScrollToAction)

    public var name: String {
        switch self {
        case .click(let click):
            click.button == .right ? "rightClick" : (click.count == 2 ? "doubleClick" : "click")
        case .type: "type"
        case .setText: "setText"
        case .key: "key"
        case .scrollTo: "scrollTo"
        }
    }
}

// MARK: - Results

/// One accessibility element, as the agent sees it.
public struct ElementInfo: Codable, Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    /// AXDescription: the label screen readers announce, often set when there is no title.
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: Rect?
    /// Actions the element supports, such as AXPress or AXShowMenu.
    public var actions: [String]
    public var pid: Int
    public var app: String?

    public init(role: String, subrole: String? = nil, title: String? = nil, label: String? = nil,
                value: String? = nil, identifier: String? = nil, frame: Rect? = nil,
                actions: [String] = [], pid: Int, app: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.actions = actions
        self.pid = pid
        self.app = app
    }

    /// The best human-readable name: title, then label, then value.
    public var name: String? {
        [title, label, value].compactMap { $0 }.first { !$0.isEmpty }
    }
}

public struct ElementQuery: Codable, Sendable, Equatable {
    public var bundleID: String
    /// Only elements that can be acted on (have actions or accept text).
    public var interactiveOnly: Bool
    public var limit: Int

    public init(bundleID: String, interactiveOnly: Bool = true, limit: Int = 300) {
        self.bundleID = bundleID
        self.interactiveOnly = interactiveOnly
        self.limit = limit
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var pid: Int
    public var isActive: Bool

    public init(bundleID: String, name: String, pid: Int, isActive: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.isActive = isActive
    }
}

/// What `quitApps` did.
public struct QuitAppsReport: Codable, Sendable, Equatable {
    /// Apps that quit.
    public var quit: [AppInfo]
    /// Apps still running when the helper stopped waiting, usually because they are asking
    /// whether to save changes.
    public var stillOpen: [AppInfo]

    public init(quit: [AppInfo], stillOpen: [AppInfo]) {
        self.quit = quit
        self.stillOpen = stillOpen
    }
}

/// How the helper carried out an action.
public enum ActionMethod: String, Codable, Sendable {
    /// Mouse down/up sent only to the app owning the visible target window.
    case pidMouse
    /// Accessibility press on a button, link, checkbox or similar.
    case axPress
    /// Accessibility "open", used for double-clicks on items that support it.
    case axOpen
    /// Accessibility context-menu action, used for right-clicks.
    case axShowMenu
    /// Accessibility focus, used for clicks on text fields.
    case axFocus
    /// Accessibility value write (set-text).
    case axSetValue
    /// Accessibility value write on a scroll area's scroll bar (absolute position).
    case axScrollBarValue
    /// Key events sent only to the focused app.
    case pidKeys
}

/// What an action did. `landed` is `nil` when the helper can't tell. The executor should
/// then check the next screenshot.
public struct ActionReport: Codable, Sendable, Equatable {
    public var action: String
    public var method: ActionMethod
    /// The element acted on, when Accessibility found one.
    public var target: ElementInfo?
    public var pid: Int?
    public var app: String?
    /// Raw AXError code of the Accessibility call (0 = success). Some apps return an error
    /// even though the action happened, so this alone doesn't decide `landed`.
    public var axError: Int?
    public var landed: Bool?
    public var detail: String

    public init(action: String, method: ActionMethod, target: ElementInfo? = nil, pid: Int? = nil,
                app: String? = nil, axError: Int? = nil, landed: Bool? = nil, detail: String) {
        self.action = action
        self.method = method
        self.target = target
        self.pid = pid
        self.app = app
        self.axError = axError
        self.landed = landed
        self.detail = detail
    }
}
