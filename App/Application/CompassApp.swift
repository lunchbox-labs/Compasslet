import SwiftUI
import UIKit

@main
struct CompassApp: App {
  @UIApplicationDelegateAdaptor(CompassAppDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup { CompassView(drive: appDelegate.drive) }
  }
}
