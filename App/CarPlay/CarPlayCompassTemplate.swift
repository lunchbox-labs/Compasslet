import CarPlay
import UIKit

/// A native summary header. CarPlay owns all layout, text and interaction.
@MainActor
final class CarPlayCompassTemplate {
  let template: CPListTemplate

  init() {
    template = CPListTemplate(title: "Compasslet", sections: [])
    template.showsSpinnerWhileEmpty = false
    // A header-only summary has no list results or loading state to announce.
    template.emptyViewTitleVariants = [""]
    template.emptyViewSubtitleVariants = [""]
  }

  /// Renders for the car display described by `traits`, which CarPlay supplies per connection.
  func update(_ value: CarPlayPresentation, traits: UITraitCollection) {
    let title: String
    let subtitle: String
    if let timestamp = value.sampleTimestamp {
      title = "Sampled \(value.bearing)"
      subtitle = "\(value.reference) · \(timestamp.formatted(date: .omitted, time: .standard))"
    } else {
      title = value.bearing
      subtitle = value.reference
    }
    template.listHeader = CPListTemplateDetailsHeader(
      thumbnail: CPThumbnailImage(
        image: Self.dialImage(course: value.courseDegrees, traits: traits)),
      title: title, subtitle: subtitle,
      bodyVariants: [NSAttributedString(string: value.status)], actionButtons: [])
  }

  /// Draws at the car display's scale, with light and dark variants registered for that scale.
  /// The returned image matches the car's current style; each update renders again.
  static func dialImage(course: Double?, traits car: UITraitCollection) -> UIImage {
    let maximum = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
    let side = min(160, maximum.width, maximum.height)
    let scale = car.displayScale > 0 ? car.displayScale : 1
    let asset = UIImageAsset()
    for style: UIUserInterfaceStyle in [.light, .dark] {
      let traits = UITraitCollection { traits in
        traits.userInterfaceStyle = style
        traits.displayScale = scale
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      format.opaque = true
      let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        .image { context in
          traits.performAsCurrent {
            drawDial(course: course, side: side, context: context.cgContext)
          }
        }
      asset.register(image, with: traits)
    }
    return asset.image(
      with: UITraitCollection { traits in
        traits.userInterfaceStyle = car.userInterfaceStyle == .dark ? .dark : .light
        traits.displayScale = scale
      })
  }

  private static func drawDial(course: Double?, side: CGFloat, context: CGContext) {
    UIColor.systemBackground.setFill()
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let center = CGPoint(x: side / 2, y: side / 2)
    let radius = side * 0.32
    UIColor.secondaryLabel.setStroke()
    context.setLineWidth(max(1, side / 100))
    context.strokeEllipse(
      in: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    for degrees in stride(from: 0, to: 360, by: 30) {
      let angle = CGFloat(degrees) * .pi / 180
      context.move(
        to: CGPoint(
          x: center.x + sin(angle) * radius * 0.87,
          y: center.y - cos(angle) * radius * 0.87))
      context.addLine(
        to: CGPoint(
          x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
      context.strokePath()
    }
    let font = UIFont.systemFont(ofSize: side * 0.105, weight: .semibold)
    for (index, label) in ["N", "E", "S", "W"].enumerated() {
      let angle = CGFloat(index) * .pi / 2
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: UIColor.label,
      ]
      let string = NSAttributedString(string: label, attributes: attributes)
      let size = string.size()
      string.draw(
        at: CGPoint(
          x: center.x + sin(angle) * side * 0.43 - size.width / 2,
          y: center.y - cos(angle) * side * 0.43 - size.height / 2))
    }
    guard let course, course.isFinite, (0..<360).contains(course) else {
      let string = NSAttributedString(
        string: "—",
        attributes: [
          .font: UIFont.systemFont(ofSize: side * 0.2), .foregroundColor: UIColor.secondaryLabel,
        ])
      let size = string.size()
      string.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
      return
    }
    // North remains at the top; only the travel-course arrow rotates.
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: CGFloat(course) * .pi / 180)
    UIColor.systemTeal.setFill()
    context.move(to: CGPoint(x: 0, y: -radius * 0.78))
    context.addLine(to: CGPoint(x: radius * 0.26, y: -radius * 0.25))
    context.addLine(to: CGPoint(x: radius * 0.08, y: -radius * 0.3))
    context.addLine(to: CGPoint(x: radius * 0.08, y: radius * 0.5))
    context.addLine(to: CGPoint(x: -radius * 0.08, y: radius * 0.5))
    context.addLine(to: CGPoint(x: -radius * 0.08, y: -radius * 0.3))
    context.addLine(to: CGPoint(x: -radius * 0.26, y: -radius * 0.25))
    context.closePath()
    context.fillPath()
    context.restoreGState()
  }
}

/// The display scale and thumbnail limit the car reported, shown in the phone's diagnostics.
@MainActor
enum CarPlayDisplayInfo {
  static let key = "carPlayDisplaySummary"

  static func summary(for traits: UITraitCollection) -> String {
    let maximum = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
    let style =
      switch traits.userInterfaceStyle {
      case .dark: "dark"
      case .light: "light"
      default: "unspecified"
      }
    let scale = traits.displayScale
    // Whole scales read as "2"; fractional ones keep their digits, independent of locale.
    let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(Double(scale))
    return "\(scaleText)× display · "
      + "\(Int(maximum.width))×\(Int(maximum.height)) pt thumbnail · \(style) style"
  }

  static func record(_ traits: UITraitCollection, defaults: UserDefaults = .standard) {
    defaults.set(summary(for: traits), forKey: key)
  }

  static func recorded(defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: key)
  }
}
