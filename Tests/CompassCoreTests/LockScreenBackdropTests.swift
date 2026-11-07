import CompassCore
import Foundation
import Testing

private struct RGB: Sendable {
  var red, green, blue: Double

  init(_ red: Double, _ green: Double, _ blue: Double) {
    (self.red, self.green, self.blue) = (red, green, blue)
  }
}

/// WCAG 2 relative luminance of an sRGB colour with components from 0 to 1.
private func luminance(_ colour: RGB) -> Double {
  func linear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green)
    + 0.0722 * linear(colour.blue)
}

private func contrast(_ first: RGB, _ second: RGB) -> Double {
  let (a, b) = (luminance(first), luminance(second))
  return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// `top` at `opacity` over `bottom`.
private func blend(_ top: RGB, _ opacity: Double, over bottom: RGB) -> RGB {
  func mix(_ upper: Double, _ lower: Double) -> Double {
    upper * opacity + lower * (1 - opacity)
  }
  return RGB(mix(top.red, bottom.red), mix(top.green, bottom.green), mix(top.blue, bottom.blue))
}

/// Every grey from black to white in 5% steps, plus the eight fully saturated corners.
private let wallpapers: [RGB] = {
  let greys = (0...20).map { step -> RGB in
    let value = Double(step) / 20
    return RGB(value, value, value)
  }
  var corners: [RGB] = []
  for red in [0.0, 1.0] {
    for green in [0.0, 1.0] {
      for blue in [0.0, 1.0] {
        corners.append(RGB(red, green, blue))
      }
    }
  }
  return greys + corners
}()

/// The lowest contrast of text over the backdrop on any of the wallpapers. The dark look tints
/// black and draws white text; the light look tints white and draws black text.
private func worstContrast(darkLook: Bool, textOpacity: Double, backdropOpacity: Double)
  -> Double
{
  let white = RGB(1, 1, 1)
  let black = RGB(0, 0, 0)
  let (ink, tint) = darkLook ? (white, black) : (black, white)
  var worst = Double.infinity
  for wallpaper in wallpapers {
    let card = blend(tint, backdropOpacity, over: wallpaper)
    worst = min(worst, contrast(blend(ink, textOpacity, over: card), card))
  }
  return worst
}

@Test(arguments: [true, false])
func lockScreenTextStaysLegibleOnAnyWallpaper(darkLook: Bool) {
  for (reduceTransparency, increaseContrast) in [(false, false), (false, true), (true, false)] {
    let backdrop = LockScreenBackdrop.opacity(
      reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    let secondary = worstContrast(
      darkLook: darkLook, textOpacity: LockScreenBackdrop.secondaryTextOpacity,
      backdropOpacity: backdrop)
    let primary = worstContrast(darkLook: darkLook, textOpacity: 1, backdropOpacity: backdrop)
    #expect(secondary >= 4.5, "secondary \(secondary) on backdrop \(backdrop)")
    #expect(primary > secondary, "primary \(primary) on backdrop \(backdrop)")
  }
}

@Test func lockScreenBackdropFollowsAccessibilitySettings() {
  #expect(LockScreenBackdrop.opacity(reduceTransparency: true, increaseContrast: true) == 1)
  let standard = LockScreenBackdrop.opacity(reduceTransparency: false, increaseContrast: false)
  let increased = LockScreenBackdrop.opacity(reduceTransparency: false, increaseContrast: true)
  // Still see-through with Increase Contrast, but more opaque.
  #expect(standard < increased && increased < 1)
}
