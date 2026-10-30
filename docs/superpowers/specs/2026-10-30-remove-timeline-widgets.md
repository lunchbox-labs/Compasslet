# Remove ordinary timeline widgets

Remove the ordinary Home Screen, Lock Screen and CarPlay timeline widget feature. Keep the ActivityKit Live Activity, its same-drive retained reading behavior, the native CarPlay app template, and the phone compass. WidgetKit remains the rendering framework for ActivityConfiguration; it is not itself being removed.

Delete the timeline registration/provider, snapshot storage and reload pipeline, widget appearance options and widget-only diagnostic stream. Preserve the extension target and bundle identity, App Group, entitlements, permissions and signing configuration because retained features still use them. Remove retired snapshot files on app initialization, discard retired diagnostics during database opening, and decode existing appearance choices without losing phone or activity overrides.

The implementation removes the feature rather than hiding its settings or disabling reloads. Those alternatives leave placements and dead acquisition/storage paths. Existing placements may need manual removal after updating. Device checks must verify the widget gallery no longer offers the feature and that the Live Activity still appears and updates in CarPlay.
