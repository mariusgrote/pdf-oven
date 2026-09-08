import Foundation
import PDFOvenKit

// Installed as `pdfoven`; the target keeps a distinct name because macOS filesystems are
// case-insensitive and `.build/release/pdfoven` would collide with the app binary.

let command: ExtractCommand
switch parseCommandLine(
  Array(CommandLine.arguments.dropFirst()),
  relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
) {
case .extract(let parsed):
  command = parsed
case .usage(let status):
  print(usage)
  exit(status)
case .failure(let message):
  // Nothing has been written at this point: a bad call fails whole, never halfway.
  FileHandle.standardError.write(Data("pdfoven: \(message)\n".utf8))
  exit(2)
}

let extractor = ImageExtractor(extractOptions: command.extractOptions)
var failures = 0
for input in command.inputs {
  do {
    let result = try extractor.extract(
      input, options: command.placement, protecting: command.inputs)
    var summary = "\(result.written) image\(result.written == 1 ? "" : "s")"
    if result.skipped > 0 { summary += ", \(result.skipped) skipped" }
    print("\(input.lastPathComponent): \(summary) → \(result.folder.path)")
  } catch {
    FileHandle.standardError.write(Data("pdfoven: \(error.localizedDescription)\n".utf8))
    failures += 1
  }
}
exit(failures == 0 ? 0 : 1)
