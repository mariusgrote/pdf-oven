import AppKit
import Foundation
import PDFOvenKit
import SwiftUI
import UniformTypeIdentifiers

enum Preference {
  static let suffix = "suffix"
  static let destinationFolder = "destinationFolderPath"
  static let replaceExisting = "replaceExisting"
  static let revealWhenDone = "revealWhenDone"

  static var defaultSuffix: String { Destination.defaultSuffix }

  static func register() {
    UserDefaults.standard.register(defaults: [
      suffix: defaultSuffix,
      replaceExisting: false,
      revealWhenDone: false,
    ])
  }

  /// The current suffix/folder/replace settings, as the library wants them.
  static var options: Options {
    let defaults = UserDefaults.standard
    return Options(
      suffix: defaults.string(forKey: suffix) ?? defaultSuffix,
      folder: defaults.string(forKey: destinationFolder).map { URL(fileURLWithPath: $0) },
      replace: defaults.bool(forKey: replaceExisting)
    )
  }
}

struct BakeItem: Identifiable {
  enum Status: Equatable {
    case waiting
    case baking
    case done(URL)
    case failed(String)
  }

  let id = UUID()
  let input: URL
  var status: Status = .waiting

  var outputURL: URL? {
    if case .done(let url) = status { return url }
    return nil
  }
}

@MainActor
final class Oven: ObservableObject {
  static let shared = Oven()

  @Published private(set) var items: [BakeItem] = []

  /// The tail of the drain chain. Every `add` links a new drain behind the last one, so a
  /// file added while a drain is finishing is picked up by the drain that follows it.
  private var drain: Task<Void, Never>?

  var isBaking: Bool {
    items.contains { $0.status == .waiting || $0.status == .baking }
  }

  func clear() {
    guard !isBaking else { return }
    items.removeAll()
  }

  /// Accepts files and folders; folders are searched (one level deep and below) for PDFs.
  func add(_ urls: [URL]) {
    let pdfs = urls.flatMap(Destination.expand(_:)).filter { url in
      !items.contains { $0.input == url }
    }
    guard !pdfs.isEmpty else { return }
    items.append(contentsOf: pdfs.map { BakeItem(input: $0) })

    let previous = drain
    drain = Task { [weak self] in
      await previous?.value
      await self?.bakePending()
    }
  }

  private func bakePending() async {
    let options = Preference.options
    let reveal = UserDefaults.standard.bool(forKey: Preference.revealWhenDone)

    while let index = items.firstIndex(where: { $0.status == .waiting }) {
      let input = items[index].input
      items[index].status = .baking
      // Every file still in the list is an input of this run and must not be written over.
      let protected = items.map(\.input)
      let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
        do {
          let output = Destination.destination(
            for: input,
            suffix: options.suffix,
            folder: options.folder,
            replace: options.replace,
            protecting: protected
          )
          try Baker.bake(input: input, to: output)
          return .success(output)
        } catch {
          return .failure(error)
        }
      }.value

      guard let current = items.firstIndex(where: { $0.input == input }) else { continue }
      switch result {
      case .success(let url):
        items[current].status = .done(url)
        if reveal {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      case .failure(let error):
        items[current].status = .failed(error.localizedDescription)
      }
    }
  }
}
