import CompassCore
import Testing

@Test func settingsSwipeRequiresIntentionalLeftwardMotion() {
  for (x, y) in [(0.0, 0.0), (100, 0), (-10, 100), (-100, 50), (-100, -60)] {
    var swipe = SettingsDismissalSwipe()
    let result1 = !swipe.begin(horizontalVelocity: x, verticalVelocity: y)
    #expect(result1)
    let result2 = !swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
    #expect(result2)
  }
  for (x, y) in [(-60.0, 0.0), (-59, 0), (-100, 50), (-100, -51), (100, 0)] {
    var swipe = SettingsDismissalSwipe()
    let result3 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 0)
    #expect(result3)
    let result4 = !swipe.finish(horizontalTranslation: x, verticalTranslation: y)
    #expect(result4)
  }
  var swipe = SettingsDismissalSwipe()
  let result5 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 1)
  #expect(result5)
  let result6 = swipe.finish(horizontalTranslation: -61, verticalTranslation: 2)
  #expect(result6)
}

@Test func cancelledAndRepeatedSettingsSwipesDoNotDismissUnexpectedly() {
  var swipe = SettingsDismissalSwipe()
  let result7 = !swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
  #expect(result7)
  let result8 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 0)
  #expect(result8)
  swipe.cancel()
  let result9 = !swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
  #expect(result9)
  let result10 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 0)
  #expect(result10)
  let result11 = swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
  #expect(result11)
  let result12 = !swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
  #expect(result12)
  let result13 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 0)
  #expect(result13)
  let result14 = !swipe.finish(horizontalTranslation: -20, verticalTranslation: 0)
  #expect(result14)
  let result15 = swipe.begin(horizontalVelocity: -100, verticalVelocity: 0)
  #expect(result15)
  let result16 = swipe.finish(horizontalTranslation: -100, verticalTranslation: 0)
  #expect(result16)
}
