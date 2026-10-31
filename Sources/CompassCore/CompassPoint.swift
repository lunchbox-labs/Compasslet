/// One of the eight principal compass points, each covering a 45-degree sector.
public enum CompassPoint: String, CaseIterable, Sendable {
  case north, northeast, east, southeast, south, southwest, west, northwest

  /// The point whose sector contains the angle; sectors are centered on each point.
  public init(angle: CompassAngle) {
    self = Self.allCases[Int((angle.degrees + 22.5) / 45) % Self.allCases.count]
  }

  /// Creates the point for a finite angle in degrees, normalizing it first.
  public init?(degrees: Double) {
    guard let angle = CompassAngle(degrees: degrees) else { return nil }
    self.init(angle: angle)
  }

  /// The one- or two-letter label used on dials and in visual readouts.
  public var abbreviation: String {
    switch self {
    case .north: "N"
    case .northeast: "NE"
    case .east: "E"
    case .southeast: "SE"
    case .south: "S"
    case .southwest: "SW"
    case .west: "W"
    case .northwest: "NW"
    }
  }

  /// The full lowercase name, suitable for spoken descriptions.
  public var name: String { rawValue }
}
