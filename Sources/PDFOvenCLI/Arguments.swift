import Foundation
import PDFOvenKit

let usage = """
  usage: pdfoven extract [options] file.pdf ...

  Writes every embedded image of each PDF into <stem>-images next to it.

  options:
    --out DIR         write the image folders inside DIR instead
    --min-size N      skip images narrower or shorter than N pixels (default 32)
    --min-bytes N     skip output smaller than N bytes (default 1024)
    --no-dedupe       write one file per time an image is painted
    --no-markup       ignore stamp annotations and attached image files
    --prefer-original keep stored JPEG bytes instead of rebuilding transparency
    --replace         write into an images folder that already exists
  """

/// A command line that asked for an extraction: what to pull out of each PDF, where the
/// image folders go, and the PDFs to read.
struct ExtractCommand {
  var extractOptions = ExtractOptions()
  var placement = Options(suffix: "", folder: nil, replace: false)
  var inputs: [URL] = []
}

/// What a command line turned out to be.
enum ParsedCommandLine {
  /// Run this extraction.
  case extract(ExtractCommand)
  /// Print the usage on stdout and stop with this status.
  case usage(Int32)
  /// Print this on stderr and stop with status 2.
  case failure(String)
}

/// Reads a command line, resolving relative paths against `directory`.
///
/// Every positional argument is checked here, before the first document is opened. A path
/// that names no PDF is a call error, and `Destination.expand` cannot say which kind: it
/// answers `[]` for a missing path, a text file and an empty folder alike. Left to it, a
/// mistyped argument either shrinks a run silently or — worse — is only noticed after the
/// arguments before it have already written their image folders. Failing the whole call
/// keeps a typo from leaving half a run on disk.
func parseCommandLine(_ arguments: [String], relativeTo directory: URL) -> ParsedCommandLine {
  do {
    return .extract(try read(arguments, relativeTo: directory))
  } catch Stop.usage(let status) {
    return .usage(status)
  } catch Stop.failure(let message) {
    return .failure(message)
  } catch {
    return .failure(error.localizedDescription)
  }
}

/// Thrown while reading a command line; `parseCommandLine` turns it into what it reports.
private enum Stop: Error {
  case usage(Int32)
  case failure(String)
}

private func read(_ arguments: [String], relativeTo directory: URL) throws -> ExtractCommand {
  var arguments = arguments
  guard let command = arguments.first else { throw Stop.usage(2) }
  arguments.removeFirst()
  guard command == "extract" else {
    if command == "-h" || command == "--help" { throw Stop.usage(0) }
    throw Stop.failure("unknown command '\(command)'\n\n\(usage)")
  }

  func number(_ flag: String) throws -> Int {
    guard let text = arguments.first, let value = Int(text), value >= 0 else {
      throw Stop.failure("\(flag) needs a non-negative number")
    }
    arguments.removeFirst()
    return value
  }

  var parsed = ExtractCommand()
  while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--out":
      guard let path = arguments.first else { throw Stop.failure("--out needs a directory") }
      arguments.removeFirst()
      parsed.placement.folder = resolve(path, relativeTo: directory)
    case "--min-size": parsed.extractOptions.minPixelSize = try number("--min-size")
    case "--min-bytes": parsed.extractOptions.minByteSize = try number("--min-bytes")
    case "--no-dedupe": parsed.extractOptions.dedupe = false
    case "--no-markup": parsed.extractOptions.includeMarkup = false
    case "--prefer-original": parsed.extractOptions.preferOriginalEncoding = true
    case "--replace": parsed.placement.replace = true
    case "-h", "--help": throw Stop.usage(0)
    default:
      guard !argument.hasPrefix("-") else { throw Stop.failure("unknown option '\(argument)'") }
      parsed.inputs.append(contentsOf: try pdfs(at: argument, relativeTo: directory))
    }
  }

  guard !parsed.inputs.isEmpty else { throw Stop.failure("no PDFs to read\n\n\(usage)") }
  return parsed
}

/// The PDFs one positional argument names, or the reason it names none.
private func pdfs(at argument: String, relativeTo directory: URL) throws -> [URL] {
  let url = resolve(argument, relativeTo: directory)
  // A URL reports a symlink as a symlink rather than as what it points at, so the type has
  // to be read off the resolved path. A link that leads nowhere resolves to itself, which
  // is how a dangling link ends up counted as missing rather than as an odd file type.
  let resolved = url.resolvingSymlinksInPath()
  switch try? resolved.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType {
  case .some(.directory):
    let found = Destination.expand(resolved)
    guard !found.isEmpty else { throw Stop.failure("no PDFs in directory: \(argument)") }
    return found
  case .some(.regular):
    guard url.pathExtension.lowercased() == "pdf" else {
      throw Stop.failure("not a PDF file: \(argument)")
    }
    return [url]
  case .none, .some(.symbolicLink):
    throw Stop.failure("file or directory not found: \(argument)")
  case .some(let type):
    throw Stop.failure("unsupported file type: \(argument) is \(name(of: type))")
  }
}

/// Relative paths are read from the working directory, the way the shell handed them over.
private func resolve(_ path: String, relativeTo directory: URL) -> URL {
  URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
}

/// Says what the path is, so the message names the type it cannot take rather than only
/// repeating that it is not a PDF.
private func name(of type: URLFileResourceType) -> String {
  switch type {
  case .socket: return "a socket"
  case .namedPipe: return "a named pipe"
  case .characterSpecial, .blockSpecial: return "a device"
  case .unknown: return "of an unknown type"
  default: return "not a regular file"
  }
}
