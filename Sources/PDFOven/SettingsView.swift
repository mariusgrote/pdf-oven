import SwiftUI

struct SettingsView: View {
  @AppStorage(Preference.suffix) private var suffix = Preference.defaultSuffix
  @AppStorage(Preference.destinationFolder) private var destinationFolder = ""
  @AppStorage(Preference.replaceExisting) private var replaceExisting = false
  @AppStorage(Preference.revealWhenDone) private var revealWhenDone = false

  var body: some View {
    Form {
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
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
}
