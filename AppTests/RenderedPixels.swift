import SwiftUI
import UIKit

/// Pixels as 8-bit sRGB with premultiplied alpha, for tests that compare what two renders drew.
struct RenderedPixels: Equatable, CustomStringConvertible {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  /// Draws into a bitmap of the given size, or gives nil when the bitmap can't be made.
  init?(width: Int, height: Int, draw: (CGContext) -> Void) {
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      draw(context)
      return true
    }
    guard drawn else { return nil }
    self.width = width
    self.height = height
    self.bytes = bytes
  }

  init?(_ image: CGImage) {
    self.init(width: image.width, height: image.height) { context in
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
  }

  // A failed comparison shows the sizes, not every byte.
  var description: String { "\(width)×\(height) pixels" }

  /// Where two renders differ, for a failed comparison's message.
  func difference(from other: RenderedPixels) -> String {
    guard width == other.width, height == other.height else { return "\(self) and \(other)" }
    var count = 0
    var largest = 0
    var first: Int?
    for pixel in 0..<(width * height) {
      let channels = (pixel * 4)..<(pixel * 4 + 4)
      let delta = channels.map { abs(Int(bytes[$0]) - Int(other.bytes[$0])) }.max() ?? 0
      guard delta > 0 else { continue }
      count += 1
      largest = max(largest, delta)
      if first == nil { first = pixel }
    }
    guard let first else { return "no pixels differ" }
    let (row, column) = first.quotientAndRemainder(dividingBy: width)
    return "\(count) pixels differ by up to \(largest), the first at row \(row), column \(column)"
  }
}

extension UIImage {
  /// The image's pixels, or nil when it has no bitmap to read.
  var renderedPixels: RenderedPixels? { cgImage.flatMap { RenderedPixels($0) } }
}

@MainActor
extension ImageRenderer {
  /// The content drawn straight into a bitmap at the renderer's scale, or nil when it has no size.
  /// This doesn't read `cgImage` or `uiImage`: on a busy simulator their image provider can time
  /// out and hand back an unfinished image, which fails to encode or compares as the wrong pixels.
  var renderedPixels: RenderedPixels? {
    var pixels: RenderedPixels?
    let scale = self.scale
    render(rasterizationScale: scale) { size, draw in
      pixels = RenderedPixels(
        width: Int((size.width * scale).rounded(.up)),
        height: Int((size.height * scale).rounded(.up))
      ) { context in
        context.scaleBy(x: scale, y: scale)
        draw(context)
      }
    }
    return pixels
  }
}
