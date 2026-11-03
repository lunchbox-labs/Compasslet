/// Completion policy for a right-edge swipe, independent of navigation depth.
public struct SettingsDismissalSwipe {
  private static let minimumDismissalTranslation: Double = 60
  private var active = false

  public init() {}

  /// Starts tracking only a predominantly leftward swipe.
  public mutating func begin(horizontalVelocity: Double, verticalVelocity: Double) -> Bool {
    active = Self.isLeftward(horizontal: horizontalVelocity, vertical: verticalVelocity)
    return active
  }

  /// Ends the swipe, dismissing only a predominantly leftward one past the minimum translation.
  public mutating func finish(horizontalTranslation: Double, verticalTranslation: Double) -> Bool {
    defer { active = false }
    return active && horizontalTranslation < -Self.minimumDismissalTranslation
      && Self.isLeftward(horizontal: horizontalTranslation, vertical: verticalTranslation)
  }

  public mutating func cancel() { active = false }

  private static func isLeftward(horizontal: Double, vertical: Double) -> Bool {
    horizontal.isFinite && vertical.isFinite && horizontal < 0
      && abs(vertical) < -horizontal / 2
  }
}
