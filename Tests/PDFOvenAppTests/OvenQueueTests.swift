import Foundation
import PDFKit
import PDFOvenFixtures
import PDFOvenKit
import XCTest

@testable import PDFOven

@MainActor
final class OvenQueueTests: XCTestCase {
  /// The same PDF can sit in the queue twice — once to bake, once to extract — and each entry
  /// has to end up with the result of its own action.
  func testSameInputBakedAndExtractedKeepsEntriesApart() async throws {
    let defaults = UserDefaults.standard
    let previousMethod = defaults.string(forKey: Preference.flatteningMethod)
    let previousOptimize = defaults.object(forKey: Preference.optimize)
    defaults.set(FlatteningMethod.redraw.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(false, forKey: Preference.optimize)
    defer {
      if let previousMethod {
        defaults.set(previousMethod, forKey: Preference.flatteningMethod)
      } else {
        defaults.removeObject(forKey: Preference.flatteningMethod)
      }
      if let previousOptimize {
        defaults.set(previousOptimize, forKey: Preference.optimize)
      } else {
        defaults.removeObject(forKey: Preference.optimize)
      }
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-oven-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("fixture.pdf")
    try FixturePDF.data().write(to: input)

    let oven = Oven()
    oven.add([input], action: .bake)
    oven.extract([input])
    XCTAssertEqual(oven.items.count, 2)

    try await waitUntilIdle(oven)

    XCTAssertFalse(oven.isBaking)
    for item in oven.items {
      guard case .done(let output, _) = item.status else {
        return XCTFail("\(item.action) ended as \(item.status)")
      }
      switch item.action {
      case .bake, .removeAnnotations:
        XCTAssertEqual(output.pathExtension, "pdf")
        XCTAssertNotEqual(output, input)
      case .extract:
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
      }
    }
  }

  func testQueuedItemKeepsThePreferencesFromWhenItWasAdded() async throws {
    let defaults = UserDefaults.standard
    let previousLinks = defaults.object(forKey: Preference.preserveLinks)
    defer {
      if let previousLinks {
        defaults.set(previousLinks, forKey: Preference.preserveLinks)
      } else {
        defaults.removeObject(forKey: Preference.preserveLinks)
      }
    }
    defaults.set(true, forKey: Preference.preserveLinks)
    let previousMethod = defaults.string(forKey: Preference.flatteningMethod)
    let previousOptimize = defaults.object(forKey: Preference.optimize)
    defer {
      if let previousMethod {
        defaults.set(previousMethod, forKey: Preference.flatteningMethod)
      } else {
        defaults.removeObject(forKey: Preference.flatteningMethod)
      }
      if let previousOptimize {
        defaults.set(previousOptimize, forKey: Preference.optimize)
      } else {
        defaults.removeObject(forKey: Preference.optimize)
      }
    }
    defaults.set(FlatteningMethod.redraw.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(false, forKey: Preference.optimize)

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-preferences-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("queued.pdf")
    try FixturePDF.data().write(to: input)

    let oven = Oven()
    oven.add([input])
    defaults.set(FlatteningMethod.pdfKit.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(true, forKey: Preference.optimize)
    defaults.set(false, forKey: Preference.preserveLinks)

    XCTAssertEqual(oven.items.first?.preferences.bake.method, .redraw)
    XCTAssertEqual(oven.items.first?.preferences.bake.optimize, false)
    XCTAssertEqual(oven.items.first?.preferences.bake.preserveLinks, true)
    try await waitUntilIdle(oven)
    guard case .done = oven.items.first?.status else {
      return XCTFail("Queued item did not finish: \(String(describing: oven.items.first?.status))")
    }
  }

  func testCompletedFileCanBeBakedAgainWithCurrentPreferences() async throws {
    let defaults = UserDefaults.standard
    let previousSuffix = defaults.string(forKey: Preference.suffix)
    let previousMethod = defaults.string(forKey: Preference.flatteningMethod)
    let previousOptimize = defaults.object(forKey: Preference.optimize)
    defer {
      if let previousSuffix {
        defaults.set(previousSuffix, forKey: Preference.suffix)
      } else {
        defaults.removeObject(forKey: Preference.suffix)
      }
      if let previousMethod {
        defaults.set(previousMethod, forKey: Preference.flatteningMethod)
      } else {
        defaults.removeObject(forKey: Preference.flatteningMethod)
      }
      if let previousOptimize {
        defaults.set(previousOptimize, forKey: Preference.optimize)
      } else {
        defaults.removeObject(forKey: Preference.optimize)
      }
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-rebake-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("rebake.pdf")
    try FixturePDF.data().write(to: input)

    defaults.set(FlatteningMethod.redraw.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(false, forKey: Preference.optimize)
    defaults.set("-first", forKey: Preference.suffix)
    let oven = Oven()
    oven.add([input])
    try await waitUntilIdle(oven)

    defaults.set("-second", forKey: Preference.suffix)
    oven.add([input])

    XCTAssertEqual(oven.items.count, 2)
    XCTAssertEqual(oven.items[0].preferences.destination.suffix, "-first")
    XCTAssertEqual(oven.items[1].preferences.destination.suffix, "-second")
    try await waitUntilIdle(oven)
    guard case .done(let output, _) = oven.items[1].status else {
      return XCTFail("Second bake did not finish: \(oven.items[1].status)")
    }
    XCTAssertEqual(output.lastPathComponent, "rebake-second.pdf")
  }

  func testMissingAppearanceRemindsOnlyAfterContinuing() async throws {
    let defaults = UserDefaults.standard
    let previousMethod = defaults.string(forKey: Preference.flatteningMethod)
    let previousOptimize = defaults.object(forKey: Preference.optimize)
    defer {
      if let previousMethod {
        defaults.set(previousMethod, forKey: Preference.flatteningMethod)
      } else {
        defaults.removeObject(forKey: Preference.flatteningMethod)
      }
      if let previousOptimize {
        defaults.set(previousOptimize, forKey: Preference.optimize)
      } else {
        defaults.removeObject(forKey: Preference.optimize)
      }
    }
    defaults.set(FlatteningMethod.pdfKit.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(false, forKey: Preference.optimize)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-choice-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.pdf")
    try FixturePDF.data().write(to: input)

    let oven = Oven()
    oven.add([input])
    try await waitUntilIdle(oven)
    guard case .annotationDecision = oven.items[0].status else {
      return XCTFail("Expected annotation choice, got \(oven.items[0].status)")
    }
    let id = oven.items[0].id
    oven.retryAnnotation(id, using: .redraw)
    try await waitUntilIdle(oven)
    XCTAssertEqual(oven.items.count, 1)
    XCTAssertEqual(oven.items[0].id, id)
    XCTAssertEqual(oven.items[0].preferences.bake.method, .redraw)
    guard case .done(let output, _) = oven.items[0].status else {
      return XCTFail("Redraw did not finish: \(oven.items[0].status)")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

    oven.add([input])
    try await waitUntilIdle(oven)
    guard case .annotationDecision(let page, _) = oven.items[1].status else {
      return XCTFail("Expected annotation choice on the second run")
    }
    oven.retryAnnotation(oven.items[1].id, using: nil)
    try await waitUntilIdle(oven)
    guard case .doneWithWarning(_, _, let warning) = oven.items[1].status else {
      return XCTFail("Accepted bake did not finish with a page reminder")
    }
    XCTAssertTrue(warning.contains("Check page \(page)"))
  }

  func testImportActionAndCheckboxesAreCapturedPerBatch() async throws {
    let configured = ProcessInfo.processInfo.environment["PDFOVEN_TEST_QPDF"]
    let candidates = [configured, "/usr/local/bin/qpdf", "/opt/homebrew/bin/qpdf"].compactMap { $0 }
    guard let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { throw XCTSkip("Set PDFOVEN_TEST_QPDF for the removal queue integration test") }
    let defaults = UserDefaults.standard
    let keys = [
      Preference.importAction, Preference.preserveLinks, Preference.preserveForms,
      Preference.optimize, Preference.flatteningMethod, Preference.suffix,
      Preference.destinationFolder, Preference.replaceExisting, Preference.revealWhenDone,
    ]
    let previous = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, previous) {
        if let value {
          defaults.set(value, forKey: key)
        } else {
          defaults.removeObject(forKey: key)
        }
      }
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfoven-import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.pdf")
    let data = FixturePDF.data()
    try data.write(to: input)
    defaults.set(false, forKey: Preference.optimize)
    defaults.set(false, forKey: Preference.revealWhenDone)
    defaults.set(false, forKey: Preference.replaceExisting)
    defaults.set(directory.path, forKey: Preference.destinationFolder)
    defaults.set("-custom-baked", forKey: Preference.suffix)
    defaults.set(FlatteningMethod.redraw.rawValue, forKey: Preference.flatteningMethod)
    defaults.set(BakeItem.Action.removeAnnotations.rawValue, forKey: Preference.importAction)
    defaults.set(false, forKey: Preference.preserveLinks)
    defaults.set(false, forKey: Preference.preserveForms)
    let oven = Oven(qpdfExecutable: URL(fileURLWithPath: helper))
    oven.add([input])
    defaults.set(BakeItem.Action.bake.rawValue, forKey: Preference.importAction)
    defaults.set(true, forKey: Preference.preserveLinks)
    oven.add([input])
    defaults.set(true, forKey: Preference.preserveForms)
    XCTAssertEqual(oven.items.map(\.action), [.removeAnnotations, .bake])
    XCTAssertFalse(oven.items[0].preferences.bake.preserveLinks)
    XCTAssertTrue(oven.items[1].preferences.bake.preserveLinks)
    XCTAssertFalse(oven.items[1].preferences.bake.preserveForms)
    try await waitUntilIdle(oven)
    let removed = try XCTUnwrap(oven.items[0].outputURL)
    let baked = try XCTUnwrap(oven.items[1].outputURL)
    XCTAssertEqual(removed.lastPathComponent, "input_cleaned.pdf")
    XCTAssertEqual(baked.lastPathComponent, "input-custom-baked.pdf")
    let clean = try XCTUnwrap(PDFDocument(url: removed))
    for index in 0..<clean.pageCount {
      XCTAssertTrue(try XCTUnwrap(clean.page(at: index)).annotations.isEmpty)
    }
    XCTAssertEqual(try Data(contentsOf: input), data)

    defaults.set(BakeItem.Action.removeAnnotations.rawValue, forKey: Preference.importAction)
    defaults.set(false, forKey: Preference.preserveLinks)
    defaults.set(false, forKey: Preference.preserveForms)
    oven.add([input])
    try await waitUntilIdle(oven)
    XCTAssertEqual(oven.items[2].outputURL?.lastPathComponent, "input_cleaned 2.pdf")
    XCTAssertEqual(try Data(contentsOf: input), data)
  }

  private func waitUntilIdle(_ oven: Oven, timeout: TimeInterval = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while oven.isBaking {
      if Date() > deadline { return XCTFail("the queue never drained") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
