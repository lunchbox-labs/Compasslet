import SwiftUI

@main
struct CompassWatchApp: App {
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        WatchCompassView()
          .navigationTitle("Compasslet")
      }
    }
  }
}
