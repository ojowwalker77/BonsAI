import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum AssetStore {
  static let storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Composer/Attachments", isDirectory: true)

  private static let maxPixelDimension = 3_000
  private static let quality = 0.85
  private static let gifType = "com.compuserve.gif" as CFString
  private static let heicType = "public.heic" as CFString
  private static let jpegType = "public.jpeg" as CFString
  private static let pngType = "public.png" as CFString

  static func ingest(fileURL: URL) -> String? {
    let url = fileURL.standardizedFileURL
    if let filename = filenameIfInsideStore(url) { return filename }
    guard FileManager.default.fileExists(atPath: url.path) else {
      log("source file does not exist: \(url.path)")
      return nil
    }
    if isGIF(url) { return copyGIF(url) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = downsampledImage(from: source) else {
      log("could not decode image: \(url.path)")
      return nil
    }
    return encodeBest(image)
  }

  static func ingest(image: NSImage) -> String? {
    guard let data = image.tiffRepresentation,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = downsampledImage(from: source) else {
      log("could not decode NSImage for ingest")
      return nil
    }
    return encodeBest(cgImage)
  }

  static func ingest(cgImage: CGImage) -> String? {
    encodeBest(downsampledImage(cgImage))
  }

  static func resolve(_ stored: String) -> URL? {
    guard !stored.isEmpty else { return nil }
    if isBareFilename(stored) {
      let url = storeDirectory.appendingPathComponent(stored)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let url = URL(fileURLWithPath: stored).standardizedFileURL
    if url.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path) { return url }
    let fallback = storeDirectory.appendingPathComponent(url.lastPathComponent)
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  static func filenameIfInsideStore(_ url: URL) -> String? {
    let standardized = url.standardizedFileURL
    let directoryPath = storeDirectory.standardizedFileURL.path
    guard standardized.path == directoryPath || standardized.path.hasPrefix(directoryPath + "/") else { return nil }
    return standardized.lastPathComponent
  }

  private static func ensureDirectory() -> Bool {
    do {
      try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
      return true
    } catch {
      log("could not create attachment directory: \(error.localizedDescription)")
      return false
    }
  }

  private static func isBareFilename(_ value: String) -> Bool {
    !value.hasPrefix("/") && !value.contains("/")
  }

  private static func isGIF(_ url: URL) -> Bool {
    if url.pathExtension.localizedCaseInsensitiveCompare("gif") == .orderedSame { return true }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source) else { return false }
    return (type as String) == (gifType as String)
  }

  private static func copyGIF(_ source: URL) -> String? {
    guard ensureDirectory() else { return nil }
    let destination = storeDirectory.appendingPathComponent("\(UUID().uuidString).gif")
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      return destination.lastPathComponent
    } catch {
      log("could not copy GIF: \(error.localizedDescription)")
      return nil
    }
  }

  private static func downsampledImage(from source: CGImageSource) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func downsampledImage(_ image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    let longest = max(width, height)
    guard longest > maxPixelDimension else { return image }
    let scale = CGFloat(maxPixelDimension) / CGFloat(longest)
    let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let alphaInfo = hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
    guard let context = CGContext(data: nil,
                                  width: Int(size.width.rounded()),
                                  height: Int(size.height.rounded()),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else {
      return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return context.makeImage() ?? image
  }

  private static func encodeBest(_ image: CGImage) -> String? {
    let sourceHasAlpha = hasAlpha(image)
    if canEncode(heicType),
       let filename = encode(image, type: heicType, fileExtension: "heic", quality: quality) {
      if !sourceHasAlpha || encodedImageHasAlpha(filename) { return filename }
      try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(filename))
    }
    if sourceHasAlpha {
      return encode(image, type: pngType, fileExtension: "png", quality: nil)
    }
    return encode(image, type: jpegType, fileExtension: "jpg", quality: quality)
      ?? encode(image, type: pngType, fileExtension: "png", quality: nil)
  }

  private static func encode(_ image: CGImage, type: CFString, fileExtension ext: String, quality: Double?) -> String? {
    guard ensureDirectory() else { return nil }
    let filename = "\(UUID().uuidString).\(ext)"
    let url = storeDirectory.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
      log("could not create image encoder for \(type)")
      return nil
    }
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: url)
      log("image encoder failed for \(type)")
      return nil
    }
    return filename
  }

  private static func canEncode(_ type: CFString) -> Bool {
    let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    return identifiers.contains(type as String)
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
      return true
    case .none, .noneSkipFirst, .noneSkipLast:
      return false
    @unknown default:
      return true
    }
  }

  private static func encodedImageHasAlpha(_ filename: String) -> Bool {
    let url = storeDirectory.appendingPathComponent(filename)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    return hasAlpha(image)
  }

  private static func log(_ message: String) {
    NSLog("Composer AssetStore: %@", message)
  }
}
