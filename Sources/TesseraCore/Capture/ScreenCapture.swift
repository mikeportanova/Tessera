import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

/// Captures a screenshot of a display via ScreenCaptureKit and returns it as base64 PNG, ready to
/// drop into a Claude image content block. ScreenCaptureKit is the only supported path on modern
/// macOS — the old `CGWindowListCreateImage` / `CGDisplayCreateImage` are obsoleted in macOS 15+.
///
/// Capture is optional: only invoked when content-aware tiling is enabled. The first call triggers
/// the Screen Recording TCC prompt.
public enum ScreenCapture {

    public enum CaptureError: Error {
        case displayNotFound
        case encodingFailed
    }

    /// Capture the given display, downscaled to `maxWidth` px to keep the payload small, and return
    /// base64-encoded PNG data plus the media type.
    public static func captureDisplayAsBase64PNG(
        displayID: CGDirectDisplayID,
        maxWidth: Int = 1600
    ) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        let scale = min(1.0, Double(maxWidth) / Double(scDisplay.width))
        config.width = max(1, Int(Double(scDisplay.width) * scale))
        config.height = max(1, Int(Double(scDisplay.height) * scale))
        config.scalesToFit = true
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        guard let pngData = cgImage.pngData() else {
            throw CaptureError.encodingFailed
        }
        return pngData.base64EncodedString()
    }
}

private extension CGImage {
    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }
}
