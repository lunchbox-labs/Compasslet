# Compasslet

See your direction on iPhone and while driving with CarPlay.

- A phone compass that works while stationary, with dial and text displays.
- A CarPlay app showing sampled travel direction.
- A compact Live Activity that shows your travel direction, and when it was recorded,
  during a drive, keeping it visible through stops.
- Support for VoiceOver, larger text and Reduce Motion.

Requires iOS 27 or later. The phone compass points relative to magnetic north;
nearby magnets and metal can affect accuracy. CarPlay shows travel relative to
true north, including reverse movement, rather than where a stationary car points.
CarPlay readings are sampled; iOS controls when the Live Activity is displayed.
Ordinary Home Screen and Lock Screen widgets are not included.

## Using CarPlay

While parked, open Compasslet on iPhone and allow While Using location access with
Precise Location. Use Settings to repair permissions if needed; Always access is
not required. Open Compasslet from the CarPlay launcher to start automatically.
Connecting a cable alone may not launch the app.

Switching to Maps keeps the drive running with the background location indicator.
The drive ends a minute after CarPlay disconnects (see
[Live Activity settings](#live-activity-settings)), when you end the Live Activity,
when location access or Precise Location is turned off, or after eight hours.
Dismissing the Live Activity ends the drive unless Compasslet is connected on CarPlay.
Open Compasslet on CarPlay again to start a new drive.

### Live Activity settings

In Compasslet's Settings, under Live Activity:

- **Refresh Rate** sets how often Compasslet sends the Live Activity a new direction during a
  drive: every second (the standard), or every 5, 15 or 30 seconds. iOS decides when the Lock
  Screen and CarPlay show each update.
- **Auto-Stop** sets how long a drive continues after CarPlay disconnects before it ends on
  its own: 1 minute (the standard), 5 or 15 minutes, or Never. Leaving the Live Activity
  running a long time may affect battery life. Drives still end after eight hours, and a drive
  started from Shortcuts or Siri away from the car still ends after a minute unless CarPlay
  connects.

