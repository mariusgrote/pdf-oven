import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFOvenApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var oven = Oven.shared

  init() { Preference.register() }

  var body: some Scene {
    Window("PDF Oven", id: "main") {
      ContentView()
        .environmentObject(oven)
        .frame(minWidth: 460, minHeight: 420)
    }
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open PDFs…") { oven.add(FilePicker.chooseInputs()) }
          .keyboardShortcut("o")
        Button("Extract Images…") { oven.extract(FilePicker.chooseExtractInputs()) }
          .keyboardShortcut("e")
      }
    }

    Settings {
      SettingsView()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in Oven.shared.add(urls) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum FilePicker {
  @MainActor
  static func chooseInputs() -> [URL] {
    chooseInputs(message: "Choose PDFs to bake", prompt: "Bake")
  }

  @MainActor
  static func chooseExtractInputs() -> [URL] {
    chooseInputs(message: "Choose PDFs to extract images from", prompt: "Extract")
  }

  @MainActor
  private static func chooseInputs(message: String, prompt: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.message = message
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.urls : []
  }

  @MainActor
  static func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.message = "Choose where baked PDFs are saved"
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
