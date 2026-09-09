import PDFOvenKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(Preference.suffix) private var suffix = Preference.defaultSuffix
  @AppStorage(Preference.destinationFolder) private var destinationFolder = ""
  @AppStorage(Preference.replaceExisting) private var replaceExisting = false
  @AppStorage(Preference.revealWhenDone) private var revealWhenDone = false
  @AppStorage(Preference.flatteningMethod) private var flatteningMethod =
    FlatteningMethod.redraw.rawValue
  @AppStorage(Preference.optimize) private var optimize = false

  private var selectedMethod: FlatteningMethod {
    FlatteningMethod(rawValue: flatteningMethod) ?? .redraw
  }

  var body: some View {
    Form {
      Picker("Flattening method:", selection: $flatteningMethod) {
        ForEach(FlatteningMethod.allCases, id: \.rawValue) { method in
          Text(method.title).tag(method.rawValue)
        }
      }
      Text(selectedMethod.explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("Losslessly optimize file size after baking", isOn: $optimize)
      Text("Recompresses PDF data without converting or downsampling images.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()

      TextField("Filename suffix:", text: $suffix, prompt: Text(Preference.defaultSuffix))
        .frame(width: 160)
      LabeledContent("Save to:") {
        HStack {
          Text(
            destinationFolder.isEmpty
              ? "Alongside the original"
              : URL(fileURLWithPath: destinationFolder).lastPathComponent
          )
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          Spacer()
          Button("Choose…") {
            if let url = FilePicker.chooseFolder() { destinationFolder = url.path }
          }
          Button("Reset") { destinationFolder = "" }
            .disabled(destinationFolder.isEmpty)
        }
      }
      Toggle("Replace an existing file with the same name", isOn: $replaceExisting)
      Toggle("Reveal each baked file in Finder", isOn: $revealWhenDone)
      LabeledContent("Version:") {
        Text(AppVersion.display)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
  }
}

extension FlatteningMethod {
  fileprivate var title: String {
    switch self {
    case .preserveContent: return "Flatten into page content (qpdf)"
    case .pdfKit: return "Native macOS burn-in (PDFKit)"
    case .redraw: return "Compatibility redraw (PDFKit)"
    }
  }

  fileprivate var explanation: String {
    switch self {
    case .preserveContent:
      return
        "Adds annotation appearances to the existing page content without redrawing the full page."
    case .pdfKit:
      return "Uses macOS to bake annotations into page content. File size may increase."
    case .redraw:
      return
        "The original PDF Oven method. Draws every page into a new PDF and may make drawings much larger."
    }
  }
}

/// Reads what build.sh stamped into the bundle, so the app reports the released version.
enum AppVersion {
  static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
  static var display: String { "\(short) (\(build))" }
}
