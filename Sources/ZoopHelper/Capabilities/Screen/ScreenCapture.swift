import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import ZoopShared

/// Screenshots of the agent session's main display, via ScreenCaptureKit.
///
/// The agent session keeps drawing its desktop while it is in the background, so this
/// works while the main user is on screen.
enum ScreenCapture {
    static func capturePNG(_ options: CaptureOptions) async throws -> (CaptureMetadata, Data) {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelperFailure(.permissionDenied, """
                Screen Recording is not allowed for ZoopHelper in \(NSUserName())'s session. \
                Switch to that user and turn on ZoopHelper in System Settings > Privacy & Security > \
                Screen & System Audio Recording.
                """)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw HelperFailure(.internalError, "no display is visible to this session")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = Double(filter.pointPixelScale)
        var width = Int(Double(display.width) * scale)
        var height = Int(Double(display.height) * scale)
        if let maxWidth = options.maxPixelWidth, maxWidth > 0, width > maxWidth {
            height = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
            width = maxWidth
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = options.showsCursor

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (CaptureMetadata(width: image.width, height: image.height, format: "png"), try encodePNG(image))
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw HelperFailure(.internalError, "could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HelperFailure(.internalError, "PNG encoding failed")
        }
        return data as Data
    }
}
