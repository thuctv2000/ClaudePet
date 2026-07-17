import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Imports user-picked PNG/JPEG/GIF files into `~/.petmacos/sprites/<state>/`,
/// replacing the state's frames. Mirrors tools/make-sprites.py: GIFs are split
/// into frames (fps derived from frame delays), every frame is trimmed to its
/// alpha bounding box and centered on a square transparent canvas so the pet
/// doesn't jump between frames.
enum SpriteImporter {
    struct ImportResult {
        let frameCount: Int
        let gifFPS: Double?
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case noFrames

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return String(format: tr("Couldn't read image: %@"), name)
            case .noFrames: return tr("No frames to import")
            }
        }
    }

    /// Replaces all frames of `state` with the given files. Runs on the main
    /// actor (called from the settings UI; a handful of frames is fast enough).
    @MainActor
    static func replaceFrames(
        of state: String, with urls: [URL], canvasSize: Int = 512, pad: CGFloat = 0.06
    ) throws -> ImportResult {
        // Keep a stable order regardless of the panel's selection order.
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var frames: [CGImage] = []
        var gifFPS: Double?
        for url in sorted {
            let (extracted, fps) = try loadFrames(from: url)
            frames.append(contentsOf: extracted)
            if let fps { gifFPS = fps }
        }
        guard !frames.isEmpty else { throw ImportError.noFrames }

        let dir = SpriteLibrary.root.appendingPathComponent(state, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where old.pathExtension.lowercased() == "png" {
            try? FileManager.default.removeItem(at: old)
        }

        for (index, frame) in frames.enumerated() {
            let normalized = trimAndCenter(frame, canvasSize: canvasSize, pad: pad)
            let out = dir.appendingPathComponent(String(format: "%@_%03d.png", state, index))
            try writePNG(normalized, to: out)
        }

        // A GIF brings its own timing; write clip.json so playback matches.
        if let fps = gifFPS {
            let config = dir.appendingPathComponent("clip.json")
            try "{\"fps\": \(fps), \"loop\": true}\n".write(to: config, atomically: true, encoding: .utf8)
        }

        return ImportResult(frameCount: frames.count, gifFPS: gifFPS)
    }

    // MARK: - Loading

    /// Returns all frames in the file plus a suggested fps for animated GIFs.
    private static func loadFrames(from url: URL) throws -> ([CGImage], Double?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImportError.unreadable(url.lastPathComponent) }

        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(image)
            if count > 1 { delays.append(gifDelay(source: source, index: index)) }
        }

        var fps: Double?
        if delays.count > 1 {
            let average = delays.reduce(0, +) / Double(delays.count)
            if average > 0 { fps = (1.0 / average * 10).rounded() / 10 }
        }
        return (frames, fps)
    }

    private static func gifDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = (unclamped ?? 0) > 0 ? unclamped! : (clamped ?? 0.1)
        return delay > 0 ? delay : 0.1
    }

    // MARK: - Normalising

    /// Crops to the alpha bounding box, then scales and centers the content on
    /// a transparent square canvas with a small margin.
    private static func trimAndCenter(_ image: CGImage, canvasSize: Int, pad: CGFloat) -> CGImage {
        let cropped = cropToAlphaBounds(image) ?? image

        let inner = CGFloat(canvasSize) * (1 - 2 * pad)
        let scale = min(inner / CGFloat(cropped.width), inner / CGFloat(cropped.height), 1000)
        let width = CGFloat(cropped.width) * scale
        let height = CGFloat(cropped.height) * scale

        let context = CGContext(
            data: nil, width: canvasSize, height: canvasSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        let origin = CGPoint(
            x: (CGFloat(canvasSize) - width) / 2,
            y: (CGFloat(canvasSize) - height) / 2
        )
        context.draw(cropped, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        return context.makeImage() ?? image
    }

    /// Finds the smallest rect containing pixels with alpha above a threshold.
    private static func cropToAlphaBounds(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Fully opaque image → no useful bounds to trim.
        if minX == 0, minY == 0, maxX == width - 1, maxY == height - 1 { return image }
        return image.cropping(to: CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
    }
}
