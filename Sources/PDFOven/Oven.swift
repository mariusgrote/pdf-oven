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
  static let preserveLinks = "preserveLinks"
  static let preserveForms = "preserveForms"
  static let importAction = "importAction"
  static let extractMinPixels = "extractMinPixels"
  static let extractMinBytes = "extractMinBytes"
  static let extractDedupe = "extractDedupe"
  static let extractIncludeMarkup = "extractIncludeMarkup"

  static var defaultSuffix: String { Destination.defaultSuffix }

  static func register() {
    UserDefaults.standard.register(defaults: [
      suffix: defaultSuffix,
      replaceExisting: false,
      revealWhenDone: false,
      flatteningMethod: FlatteningMethod.redraw.rawValue,
      optimize: false,
      preserveLinks: true,
      preserveForms: false,
      importAction: BakeItem.Action.bake.rawValue,
      extractMinPixels: 32,
      extractMinBytes: 1024,
      extractDedupe: true,
      extractIncludeMarkup: true,
    ])
  }

  /// The current suffix/folder/replace settings, as the library wants them.
  static var options: Options {
    let defaults = UserDefaults.standard
    return Options(
      suffix: defaults.string(forKey: suffix) ?? defaultSuffix,
      folder: defaults.string(forKey: destinationFolder).flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
      },
      replace: defaults.bool(forKey: replaceExisting)
    )
  }

  static var bakeOptions: BakeOptions {
    let defaults = UserDefaults.standard
    let method =
      defaults.string(forKey: flatteningMethod)
      .flatMap(FlatteningMethod.init(rawValue:)) ?? .redraw
    return BakeOptions(
      method: method, optimize: defaults.bool(forKey: optimize),
      preserveLinks: defaults.object(forKey: preserveLinks) as? Bool ?? true,
      preserveForms: defaults.bool(forKey: preserveForms)
    )
  }

  static var extractOptions: ExtractOptions {
    let defaults = UserDefaults.standard
    return ExtractOptions(
      includeMarkup: defaults.object(forKey: extractIncludeMarkup) as? Bool ?? true,
      dedupe: defaults.object(forKey: extractDedupe) as? Bool ?? true,
      minPixelSize: max(0, defaults.object(forKey: extractMinPixels) as? Int ?? 32),
      minByteSize: max(0, defaults.object(forKey: extractMinBytes) as? Int ?? 1024)
    )
  }

  static var selectedAction: BakeItem.Action {
    let value = UserDefaults.standard.string(forKey: importAction)
    return value.flatMap(BakeItem.Action.init(rawValue:)) ?? .bake
  }

  static var snapshot: RunPreferences {
    RunPreferences(
      destination: options,
      bake: bakeOptions,
      extract: extractOptions,
      reveal: UserDefaults.standard.bool(forKey: revealWhenDone)
    )
  }
}

struct RunPreferences: Sendable {
  let destination: Options
  let bake: BakeOptions
  let extract: ExtractOptions
  let reveal: Bool
}

struct BakeItem: Identifiable {
  enum Action: String, Equatable, Sendable {
    case bake
    case extract
    case removeAnnotations

    var workingLabel: String {
      switch self {
      case .bake: return "Baking…"
      case .extract: return "Extracting…"
      case .removeAnnotations: return "Removing annotations…"
      }
    }
  }

  enum Status: Equatable {
    case waiting
    case working
    case done(URL, String)
    case doneWithWarning(URL, String, String)
    case failed(String)
    case annotationDecision(page: Int, subtype: String)

    var isPending: Bool {
      switch self {
      case .waiting, .working: return true
      case .done, .doneWithWarning, .failed, .annotationDecision: return false
      }
    }
  }

  let id = UUID()
  let input: URL
  let action: Action
  var preferences: RunPreferences
  var status: Status = .waiting
  var annotationPageToCheck: Int?

  var outputURL: URL? {
    if case .done(let url, _) = status { return url }
    if case .doneWithWarning(let url, _, _) = status { return url }
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
  private var reservedOutputs: [URL] = []
  private let qpdfExecutable: URL?

  /// Tests may inject a helper; the app uses the bundled executable.
  init(qpdfExecutable: URL? = nil) {
    self.qpdfExecutable = qpdfExecutable
  }

  var isBaking: Bool {
    items.contains { $0.status == .waiting || $0.status == .working }
  }

  func clear() {
    guard !isBaking else { return }
    items.removeAll()
    reservedOutputs.removeAll()
  }

  /// Accepts files and folders; folders are searched (one level deep and below) for PDFs.
  func add(_ urls: [URL], action requestedAction: BakeItem.Action? = nil) {
    let action = requestedAction ?? Preference.selectedAction
    var seen = Set(
      items.filter { $0.action == action && $0.status.isPending }
        .map { Destination.identity(of: $0.input) })
    let pdfs = urls.flatMap(Destination.expand(_:)).filter {
      seen.insert(Destination.identity(of: $0)).inserted
    }
    guard !pdfs.isEmpty else { return }
    let snapshot = Preference.snapshot
    var bake = snapshot.bake
    bake.qpdfExecutable = qpdfExecutable
    let preferences = RunPreferences(
      destination: snapshot.destination, bake: bake, extract: snapshot.extract,
      reveal: snapshot.reveal)
    items.append(
      contentsOf: pdfs.map {
        BakeItem(input: $0, action: action, preferences: preferences)
      })

    scheduleDrain()
  }

  func extract(_ urls: [URL]) { add(urls, action: .extract) }

  func retryAnnotation(_ id: UUID, using method: FlatteningMethod?) {
    guard let index = items.firstIndex(where: { $0.id == id }),
      case .annotationDecision(let page, _) = items[index].status
    else { return }
    var bake = items[index].preferences.bake
    // Redrawing cannot retain the original editable form structure.
    guard method != .redraw || !bake.preserveForms else { return }
    if let method {
      bake.method = method
    } else {
      bake.allowMissingAppearance = true
    }
    let previous = items[index].preferences
    items[index].preferences = RunPreferences(
      destination: previous.destination, bake: bake, extract: previous.extract,
      reveal: previous.reveal)
    items[index].annotationPageToCheck = method == nil ? page : nil
    items[index].status = .waiting
    scheduleDrain()
  }

  private func scheduleDrain() {
    let previous = drain
    drain = Task { [weak self] in
      await previous?.value
      await self?.processPending()
    }
  }

  private func processPending() async {
    while let index = items.firstIndex(where: { $0.status == .waiting }) {
      let itemID = items[index].id
      let input = items[index].input
      let action = items[index].action
      let preferences = items[index].preferences
      let annotationPageToCheck = items[index].annotationPageToCheck
      items[index].status = .working
      // Every file still in the list is an input of this run and must not be written over.
      let protected = items.map(\.input)
      let reserved = reservedOutputs
      let output: URL
      if action == .extract {
        output = Destination.imagesFolder(
          for: input, folder: preferences.destination.folder,
          replace: preferences.destination.replace, protecting: protected, reserving: reserved)
      } else {
        output = Destination.destination(
          for: input,
          suffix: action == .removeAnnotations
            ? Destination.cleanedSuffix : preferences.destination.suffix,
          folder: preferences.destination.folder, replace: preferences.destination.replace,
          protecting: protected, reserving: reserved)
      }
      // Reserve before processing, including failed runs that may have written partial images.
      reservedOutputs.append(output)
      let result = await Task.detached(priority: .userInitiated) {
        () -> Result<(URL, String, String?), Error> in
        do {
          switch action {
          case .bake, .removeAnnotations:
            let baked: BakeResult
            if action == .removeAnnotations {
              baked = try Baker.removeAnnotations(
                input: input, to: output, optimize: preferences.bake.optimize,
                preserveLinks: preferences.bake.preserveLinks,
                preserveForms: preferences.bake.preserveForms,
                qpdfExecutable: preferences.bake.qpdfExecutable)
            } else {
              baked = try Baker.bake(input: input, to: output, options: preferences.bake)
            }
            var detail =
              ByteCountFormatter.string(fromByteCount: Int64(baked.inputBytes), countStyle: .file)
              + " → "
              + ByteCountFormatter.string(
                fromByteCount: Int64(baked.outputBytes), countStyle: .file)
            if action == .removeAnnotations { detail = "Annotations removed · " + detail }
            if baked.usedOptimizedFile { detail += " · losslessly compressed" }
            return .success((output, detail, baked.optimizationWarning))
          case .extract:
            let extracted = try ImageExtractor(extractOptions: preferences.extract).extract(
              input, options: preferences.destination, protecting: protected, reserving: reserved)
            var detail =
              "\(extracted.written) image\(extracted.written == 1 ? "" : "s") · "
              + ByteCountFormatter.string(
                fromByteCount: Int64(extracted.bytes), countStyle: .file)
            if !extracted.skippedSummary.isEmpty { detail += " · " + extracted.skippedSummary }
            return .success((extracted.folder, detail, extracted.warning))
          }
        } catch {
          return .failure(error)
        }
      }.value

      // The same file can be queued for multiple actions, so the entry is
      // found again by its id; matching on the input alone would update the wrong one.
      guard let current = items.firstIndex(where: { $0.id == itemID }) else { continue }
      switch result {
      case .success(let completion):
        var warnings: [String] = []
        if let page = annotationPageToCheck {
          warnings.append("Check page \(page) in the saved PDF. The annotation may be missing.")
        }
        if let warning = completion.2 {
          warnings.append(
            action == .extract
              ? warning : "Saved uncompressed. Compression failed: \(warning)")
        }
        if !warnings.isEmpty {
          items[current].status = .doneWithWarning(
            completion.0, completion.1, warnings.joined(separator: " "))
        } else {
          items[current].status = .done(completion.0, completion.1)
        }
        if preferences.reveal {
          NSWorkspace.shared.activateFileViewerSelecting([completion.0])
        }
      case .failure(let error):
        if case BakeError.annotationHasNoAppearance(let page, let subtype) = error {
          items[current].status = .annotationDecision(page: page, subtype: subtype)
        } else {
          items[current].status = .failed(error.localizedDescription)
        }
      }
    }
  }
}
