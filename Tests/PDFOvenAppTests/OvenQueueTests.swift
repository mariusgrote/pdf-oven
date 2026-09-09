import Foundation
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
      case .bake:
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

    XCTAssertEqual(oven.items.first?.preferences.bake.method, .redraw)
    XCTAssertEqual(oven.items.first?.preferences.bake.optimize, false)
    try await waitUntilIdle(oven)
    guard case .done = oven.items.first?.status else {
      return XCTFail("Queued item did not finish: \(String(describing: oven.items.first?.status))")
    }
  }

  private func waitUntilIdle(_ oven: Oven, timeout: TimeInterval = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while oven.isBaking {
      if Date() > deadline { return XCTFail("the queue never drained") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
