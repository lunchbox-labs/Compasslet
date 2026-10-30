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

  func update(_ value: CarPlayPresentation) {
    template.listHeader = CPListTemplateDetailsHeader(
      thumbnail: CPThumbnailImage(image: Self.dialImage(course: value.courseDegrees)),
      title: value.bearing, subtitle: value.reference,
      bodyVariants: [
        NSAttributedString(string: "\(value.status)\n\(value.compact)"),
        NSAttributedString(string: value.status),
      ], actionButtons: [])
  }

  static func dialImage(course: Double?) -> UIImage {
    let maximum = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
    let side = min(160, maximum.width, maximum.height)
    let asset = UIImageAsset()
    for style: UIUserInterfaceStyle in [.light, .dark] {
      let traits = UITraitCollection { traits in
        traits.userInterfaceStyle = style
        traits.displayScale = 1
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        .image { context in
          traits.performAsCurrent {
            drawDial(course: course, side: side, context: context.cgContext)
          }
        }
      asset.register(image, with: traits)
    }
    return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
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
