import AVFoundation
import Foundation

/// Reports changes to whether the iPhone's audio route goes to CarPlay. A CarPlay automation
/// can start a drive before Compasslet's CarPlay scene connects, so the route is how the drive
/// knows the car is still connected. The drive also reads `isConnected` itself, because a
/// suspended app can miss a notification. Reading the route doesn't activate an audio session.
@MainActor
final class CarAudioRouteMonitor {
  private var observer: NSObjectProtocol?

  init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
    onChange(Self.isConnected)
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { onChange(CarAudioRouteMonitor.isConnected) }
    }
  }

  isolated deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  static var isConnected: Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
  }
}
