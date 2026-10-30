import SwiftUI
import UIKit
import WidgetKit

struct DiagnosticsSettingsSection: View {
  @State private var enabled = false
  @State private var error: String?
  @State private var exportURL: URL?
  @State private var showingExport = false
  @State private var confirmingClear = false

  var body: some View {
    Section("Diagnostics") {
      Toggle("Debug Mode", isOn: Binding(get: { enabled }, set: setEnabled))
      Text(
        "Show small timing details and save local diagnostics. Turning off hides timing details and keeps saved logs. Up to 30 active-feed minutes per display; timing does not measure visibility or screen refresh."
      )
      .font(.footnote).foregroundStyle(.secondary)
      Button("Export Diagnostics", action: export)
      Button("Clear Logs", role: .destructive) { confirmingClear = true }
      if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
    }
    .task {
      do { enabled = try store().isEnabled() } catch { self.error = error.localizedDescription }
    }
    .confirmationDialog("Delete the saved diagnostic logs?", isPresented: $confirmingClear) {
      Button("Clear Logs", role: .destructive) {
        do { try store().clear(); error = nil } catch { self.error = error.localizedDescription }
      }
    }
    .sheet(isPresented: $showingExport, onDismiss: removeExport) {
      if let exportURL { DiagnosticsShareSheet(url: exportURL) }
    }
  }

  private func store() throws -> CompassDiagnostics {
    guard let store = CompassDiagnostics.shared else {
      throw CompassDiagnostics.Failure.unavailable
    }
    return store
  }

  private func setEnabled(_ value: Bool) {
    do {
      try store().setEnabled(value)
      enabled = value
      error = nil
      // A configuration change may request a redraw, but WidgetKit chooses when to deliver it.
      WidgetCenter.shared.reloadTimelines(ofKind: "CompassRefreshProbe")
    } catch { self.error = error.localizedDescription }
  }

  private func export() {
    do {
      removeExport()
      let data = try store().exportJSON()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("compass-diagnostics.json")
      try data.write(to: url, options: .atomic)
      exportURL = url
      showingExport = true
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func removeExport() {
    if let exportURL {
      try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
    }
    exportURL = nil
  }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
