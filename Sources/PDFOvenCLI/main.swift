import Foundation
import PDFOvenKit

// Installed as `pdfoven`; the target keeps a distinct name because macOS filesystems are
// case-insensitive and `.build/release/pdfoven` would collide with the app binary.

let usage = """
  usage: pdfoven extract [options] file.pdf ...

  Writes every embedded image of each PDF into <stem>-images next to it.

  options:
    --out DIR         write the image folders inside DIR instead
    --min-size N      skip images narrower or shorter than N pixels (default 32)
    --min-bytes N     skip output smaller than N bytes (default 1024)
    --no-dedupe       write one file per time an image is painted
    --no-markup       ignore stamp annotations and attached image files
    --no-index        do not write index.json
    --prefer-original keep stored JPEG bytes instead of rebuilding transparency
    --replace         write into an images folder that already exists
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("pdfoven: \(message)\n".utf8))
  exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(usage)
  exit(2)
}
arguments.removeFirst()
guard command == "extract" else {
  if command == "-h" || command == "--help" {
    print(usage)
    exit(0)
  }
  fail("unknown command '\(command)'\n\n\(usage)")
}

var extractOptions = ExtractOptions()
var placement = Options(suffix: "", folder: nil, replace: false)
var inputs: [URL] = []

func number(_ flag: String) -> Int {
  guard let value = arguments.first, let parsed = Int(value), parsed >= 0 else {
    fail("\(flag) needs a non-negative number")
  }
  arguments.removeFirst()
  return parsed
}

while let argument = arguments.first {
  arguments.removeFirst()
  switch argument {
  case "--out":
    guard let path = arguments.first else { fail("--out needs a directory") }
    arguments.removeFirst()
    placement.folder = URL(fileURLWithPath: path)
  case "--min-size": extractOptions.minPixelSize = number("--min-size")
  case "--min-bytes": extractOptions.minByteSize = number("--min-bytes")
  case "--no-dedupe": extractOptions.dedupe = false
  case "--no-markup": extractOptions.includeMarkup = false
  case "--no-index": extractOptions.writeIndex = false
  case "--prefer-original": extractOptions.preferOriginalEncoding = true
  case "--replace": placement.replace = true
  case "-h", "--help":
    print(usage)
    exit(0)
  default:
    guard !argument.hasPrefix("-") else { fail("unknown option '\(argument)'") }
    inputs.append(contentsOf: Destination.expand(URL(fileURLWithPath: argument)))
  }
}

guard !inputs.isEmpty else { fail("no PDFs to read\n\n\(usage)") }

let extractor = ImageExtractor(extractOptions: extractOptions)
var failures = 0
for input in inputs {
  do {
    let result = try extractor.extract(input, options: placement, protecting: inputs)
    var summary = "\(result.written) image\(result.written == 1 ? "" : "s")"
    if result.skipped > 0 { summary += ", \(result.skipped) skipped" }
    print("\(input.lastPathComponent): \(summary) → \(result.folder.path)")
  } catch {
    FileHandle.standardError.write(Data("pdfoven: \(error.localizedDescription)\n".utf8))
    failures += 1
  }
}
exit(failures == 0 ? 0 : 1)
