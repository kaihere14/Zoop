import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screenshots arrive as PNG (about 1.5 MB at 1470×956). JPEG keeps the same size in pixels,
/// so coordinates stay valid, at a fraction of the bytes sent to the model each step.
enum ImageCompression {
    static func jpeg(fromPNG png: Data, quality: Double = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
