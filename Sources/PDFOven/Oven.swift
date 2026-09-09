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
  static let flatteningMethod = "flatteningMethod"
  static let optimize = "optimize"

  static var defaultSuffix: String { Destination.defaultSuffix }

  static func register() {
    UserDefaults.standard.register(defaults: [
      suffix: defaultSuffix,
      replaceExisting: false,
      revealWhenDone: false,
      flatteningMethod: FlatteningMethod.redraw.rawValue,
      optimize: false,
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

  static var bakeOptions: BakeOptions {
    let defaults = UserDefaults.standard
    let method =
      defaults.string(forKey: flatteningMethod)
      .flatMap(FlatteningMethod.init(rawValue:)) ?? .redraw
    return BakeOptions(method: method, optimize: defaults.bool(forKey: optimize))
  }

  static var snapshot: RunPreferences {
    RunPreferences(
      destination: options,
      bake: bakeOptions,
      reveal: UserDefaults.standard.bool(forKey: revealWhenDone)
    )
  }
}

struct RunPreferences: Sendable {
  let destination: Options
  let bake: BakeOptions
  let reveal: Bool
}

struct BakeItem: Identifiable {
  enum Action: Equatable, Sendable {
    case bake
    case extract

    var workingLabel: String {
      switch self {
      case .bake: return "Baking…"
      case .extract: return "Extracting…"
      }
    }
  }

  enum Status: Equatable {
    case waiting
    case working
    case done(URL, String)
    case failed(String)
  }

  let id = UUID()
  let input: URL
  let action: Action
  let preferences: RunPreferences
  var status: Status = .waiting

  var outputURL: URL? {
    if case .done(let url, _) = status { return url }
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
    items.contains { $0.status == .waiting || $0.status == .working }
  }

  func clear() {
    guard !isBaking else { return }
    items.removeAll()
  }

  /// Accepts files and folders; folders are searched (one level deep and below) for PDFs.
  func add(_ urls: [URL], action: BakeItem.Action = .bake) {
    let pdfs = urls.flatMap(Destination.expand(_:)).filter { url in
      !items.contains { $0.input == url && $0.action == action }
    }
    guard !pdfs.isEmpty else { return }
    let preferences = Preference.snapshot
    items.append(
      contentsOf: pdfs.map {
        BakeItem(input: $0, action: action, preferences: preferences)
      })

    let previous = drain
    drain = Task { [weak self] in
      await previous?.value
      await self?.processPending()
    }
  }

  func extract(_ urls: [URL]) { add(urls, action: .extract) }

  private func processPending() async {
    while let index = items.firstIndex(where: { $0.status == .waiting }) {
      let itemID = items[index].id
      let input = items[index].input
      let action = items[index].action
      let preferences = items[index].preferences
      items[index].status = .working
      // Every file still in the list is an input of this run and must not be written over.
      let protected = items.map(\.input)
      let result = await Task.detached(priority: .userInitiated) {
        () -> Result<(URL, String), Error> in
        do {
          switch action {
          case .bake:
            let output = Destination.destination(
              for: input,
              suffix: preferences.destination.suffix,
              folder: preferences.destination.folder,
              replace: preferences.destination.replace,
              protecting: protected
            )
            let baked = try Baker.bake(input: input, to: output, options: preferences.bake)
            var detail =
              ByteCountFormatter.string(fromByteCount: Int64(baked.inputBytes), countStyle: .file)
              + " → "
              + ByteCountFormatter.string(
                fromByteCount: Int64(baked.outputBytes), countStyle: .file)
            if baked.usedOptimizedFile { detail += " · optimized" }
            return .success((output, detail))
          case .extract:
            let extracted = try ImageExtractor().extract(
              input, options: preferences.destination, protecting: protected)
            var detail =
              "\(extracted.written) image\(extracted.written == 1 ? "" : "s") · "
              + ByteCountFormatter.string(
                fromByteCount: Int64(extracted.bytes), countStyle: .file)
            if extracted.skipped > 0 { detail += " · \(extracted.skipped) skipped" }
            return .success((extracted.folder, detail))
          }
        } catch {
          return .failure(error)
        }
      }.value

      // The same file can be queued twice — once to bake, once to extract — so the entry is
      // found again by its id; matching on the input alone would update the wrong one.
      guard let current = items.firstIndex(where: { $0.id == itemID }) else { continue }
      switch result {
      case .success(let completion):
        items[current].status = .done(completion.0, completion.1)
        if preferences.reveal {
          NSWorkspace.shared.activateFileViewerSelecting([completion.0])
        }
      case .failure(let error):
        items[current].status = .failed(error.localizedDescription)
      }
    }
  }
}
