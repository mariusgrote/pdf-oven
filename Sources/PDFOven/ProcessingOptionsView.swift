import PDFOvenKit
import SwiftUI

/// Options for the next import, shown below the drop zone for every action.
struct ProcessingOptionsView: View {
  let action: BakeItem.Action

  @AppStorage(Preference.suffix) private var suffix = Preference.defaultSuffix
  @AppStorage(Preference.flatteningMethod) private var flatteningMethod =
    FlatteningMethod.redraw.rawValue
  @AppStorage(Preference.optimize) private var optimize = false
  @AppStorage(Preference.preserveLinks) private var preserveLinks = true
  @AppStorage(Preference.preserveForms) private var preserveForms = false
  @AppStorage(Preference.extractMinPixels) private var extractMinPixels = 32
  @AppStorage(Preference.extractMinBytes) private var extractMinBytes = 1024
  @AppStorage(Preference.extractDedupe) private var extractDedupe = true
  @AppStorage(Preference.extractIncludeMarkup) private var extractIncludeMarkup = true

  private var selectedMethod: FlatteningMethod {
    preserveForms ? .preserveContent : (FlatteningMethod(rawValue: flatteningMethod) ?? .redraw)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(action == .extract ? "Extraction options" : "PDF options")
        .font(.headline)
      if action == .extract {
        Toggle("Combine duplicate images", isOn: $extractDedupe)
        Toggle("Include images from annotations and attachments", isOn: $extractIncludeMarkup)
        HStack {
          Text("Minimum width and height (pixels)")
          Spacer()
          TextField("Minimum pixels", value: $extractMinPixels, format: .number.grouping(.never))
            .frame(width: 85)
        }
        HStack {
          Text("Minimum file size (bytes)")
          Spacer()
          TextField("Minimum bytes", value: $extractMinBytes, format: .number.grouping(.never))
            .frame(width: 85)
        }
        Text("Set either minimum to 0 to disable that filter.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Toggle("Keep hyperlinks clickable", isOn: $preserveLinks)
        Toggle("Keep form fields editable", isOn: $preserveForms)
        if action == .bake {
          if preserveForms {
            LabeledContent("Baking method") {
              Text(FlatteningMethod.preserveContent.title)
            }
          } else {
            Picker("Baking method", selection: $flatteningMethod) {
              ForEach(FlatteningMethod.allCases, id: \.rawValue) { method in
                Text(method.title).tag(method.rawValue)
              }
            }
          }
          Text(
            preserveForms
              ? "Keeping editable forms uses content-preserving baking."
              : selectedMethod.explanation
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          HStack {
            Text("Baked filename suffix")
            Spacer()
            TextField("Suffix", text: $suffix, prompt: Text(Preference.defaultSuffix))
              .frame(width: 160)
          }
        }
        Toggle("Losslessly compress processed PDFs with qpdf", isOn: $optimize)
        Text(
          "Recompresses Flate streams and packs PDF objects. Images are never converted or downsampled."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text("Options apply to newly added PDFs. Queued files keep their existing options.")
        .font(.caption)
        .foregroundStyle(.secondary)

    }
    .toggleStyle(.checkbox)
    .onChange(of: extractMinPixels) { _, value in
      if value < 0 { extractMinPixels = 0 }
    }
    .onChange(of: extractMinBytes) { _, value in
      if value < 0 { extractMinBytes = 0 }
    }
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
