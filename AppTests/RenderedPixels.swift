import SwiftUI
import UIKit

/// An image's pixels as 8-bit sRGB with premultiplied alpha, for tests that compare what two
/// renders drew. Encoding an image as PNG can fail on a busy simulator and give nil, so tests
/// compare these instead.
struct RenderedPixels: Equatable, CustomStringConvertible {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init?(_ image: CGImage) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard drawn else { return nil }
    width = image.width
    height = image.height
    self.bytes = bytes
  }

  // A failed comparison shows the sizes, not every byte.
  var description: String { "\(width)×\(height) pixels" }
}

extension UIImage {
  /// The image's pixels, or nil when it has no bitmap to read.
  var renderedPixels: RenderedPixels? { cgImage.flatMap { RenderedPixels($0) } }
}

extension ImageRenderer {
  /// The rendered pixels, or nil when the content could not be rendered.
  var renderedPixels: RenderedPixels? { cgImage.flatMap { RenderedPixels($0) } }
}
