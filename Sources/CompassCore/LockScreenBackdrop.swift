/// The see-through backdrop behind the Lock Screen Live Activity, and the text drawn on it.
///
/// The card is tinted black when the Lock Screen gives it the dark look and white when it gives
/// it the light look, so the wallpaper shows through. These values keep the text at 4.5:1 or
/// better even over the wallpaper's brightest or darkest spot: the backdrop at `standardOpacity`
/// with secondary text in the primary colour at `secondaryTextOpacity`.
public enum LockScreenBackdrop {
  /// How opaque the tint is normally.
  public static let standardOpacity = 0.6
  /// How opaque the tint is with Increase Contrast on.
  public static let increasedContrastOpacity = 0.8
  /// Secondary text, such as Last Updated, as a fraction of the primary text colour. The system
  /// secondary colour is too faint over a bright wallpaper.
  public static let secondaryTextOpacity = 0.85

  /// Reduce Transparency keeps a solid card, as the system's own background would be.
  public static func opacity(reduceTransparency: Bool, increaseContrast: Bool) -> Double {
    if reduceTransparency { return 1 }
    return increaseContrast ? increasedContrastOpacity : standardOpacity
  }
}
