import Foundation

/// How an operation names and places what it writes.
public struct Options: Sendable {
  /// Appended to each input's stem. Empty means "keep the name" and only makes sense
  /// together with `folder`; `Destination` falls back to the default suffix otherwise.
  public var suffix: String
  /// Where output is written. `nil` means alongside each input.
  public var folder: URL?
  /// Overwrite an existing file of the same name instead of numbering around it.
  /// Never applies to a file this run reads from.
  public var replace: Bool

  public init(
    suffix: String = Destination.defaultSuffix,
    folder: URL? = nil,
    replace: Bool = false
  ) {
    self.suffix = suffix
    self.folder = folder
    self.replace = replace
  }
}

/// One file an operation wrote, with the sizes that went in and came out so callers can
/// report what the operation saved.
public struct OperationResult: Sendable {
  public var output: URL
  public var inputBytes: Int
  public var outputBytes: Int

  public init(output: URL, inputBytes: Int, outputBytes: Int) {
    self.output = output
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
  }
}

/// A single transformation over PDFs. Bake, merge, split and strip are all n-in/m-out,
/// so inputs and results are arrays even when an operation only ever handles one file.
public protocol PDFOperation: Sendable {
  var name: String { get }
  func run(inputs: [URL], options: Options) throws -> [OperationResult]
}
