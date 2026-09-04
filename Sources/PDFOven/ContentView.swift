import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var oven: Oven
  @State private var isTargeted = false

  var body: some View {
    VStack(spacing: 0) {
      DropZone(isTargeted: isTargeted) { oven.add(FilePicker.chooseInputs()) }
        .padding(20)

      if !oven.items.isEmpty {
        Divider()
        List(oven.items) { item in
          BakeRow(item: item)
        }
        .listStyle(.inset)
        .frame(minHeight: 120)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      oven.add(urls)
      return true
    } isTargeted: {
      isTargeted = $0
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          oven.add(FilePicker.chooseInputs())
        } label: {
          Label("Open PDFs", systemImage: "plus")
        }
        .help("Open PDFs to bake")
      }
      ToolbarItem {
        Button {
          oven.clear()
        } label: {
          Label("Clear", systemImage: "xmark.circle")
        }
        .disabled(oven.items.isEmpty || oven.isBaking)
        .help("Clear the list")
      }
    }
    .navigationTitle("PDF Oven")
  }
}

private struct DropZone: View {
  let isTargeted: Bool
  let onClick: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "doc.on.doc")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
      Text("Drop PDFs here")
        .font(.title3)
      Text("Annotations are painted into the page and saved as a new file.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Choose Files…", action: onClick)
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )
    }
  }
}

private struct BakeRow: View {
  let item: BakeItem

  var body: some View {
    HStack(spacing: 10) {
      statusIcon
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.input.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(isFailed ? Color.red : .secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if let output = item.outputURL {
        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
          .buttonStyle(.borderless)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch item.status {
    case .waiting:
      Image(systemName: "clock").foregroundStyle(.secondary)
    case .baking:
      ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
  }

  private var isFailed: Bool {
    if case .failed = item.status { return true }
    return false
  }

  private var subtitle: String {
    switch item.status {
    case .waiting: return "Waiting"
    case .baking: return "Baking…"
    case .done(let url): return url.lastPathComponent
    case .failed(let message): return message
    }
  }
}
