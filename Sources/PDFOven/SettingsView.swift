import SwiftUI

/// Shared output preferences that apply to every action.
struct SettingsView: View {
  @AppStorage(Preference.destinationFolder) private var destinationFolder = ""
  @AppStorage(Preference.replaceExisting) private var replaceExisting = false
  @AppStorage(Preference.revealWhenDone) private var revealWhenDone = false

  var body: some View {
    Form {
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
          .help(destinationFolder.isEmpty ? "Alongside the original" : destinationFolder)
          Spacer()
          Button("Choose…") {
            if let url = FilePicker.chooseFolder() { destinationFolder = url.path }
          }
          Button("Reset") { destinationFolder = "" }
            .disabled(destinationFolder.isEmpty)
        }
      }
      Toggle("Replace existing results with the same name", isOn: $replaceExisting)
      Text(
        "For image extraction, replacement reuses an existing folder and replaces matching image files. Results from the current run always receive distinct names."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Toggle("Reveal each result in Finder", isOn: $revealWhenDone)
      Text("These settings apply to all actions and newly added PDFs.")
        .font(.caption)
        .foregroundStyle(.secondary)
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
