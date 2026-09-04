import Foundation

/// Works out where an operation's output goes, and which inputs it may read.
public enum Destination {
  /// Appended to the stem when the caller gives no suffix of its own.
  public static let defaultSuffix = "-baked"

  /// Picks an output URL for `input`, honouring the caller's suffix, folder and replace
  /// preferences. `protecting` lists files the output must never land on — the input
  /// itself is always protected, so an operation can't overwrite what it is reading.
  public static func destination(
    for input: URL,
    suffix: String,
    folder: URL?,
    replace: Bool,
    protecting others: [URL] = []
  ) -> URL {
    let directory = folder ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent
    let trimmed = suffix.trimmingCharacters(in: .whitespaces)
    let protected = Set(([input] + others).map(identity(of:)))

    func candidate(_ base: String) -> URL {
      directory.appendingPathComponent(stem + base).appendingPathExtension("pdf")
    }

    // An empty suffix only makes sense when the output lands in a different folder; if it
    // still collides with an input, fall back to the default rather than eat the original.
    var base = trimmed.isEmpty && folder == nil ? defaultSuffix : trimmed
    var output = candidate(base)
    if protected.contains(identity(of: output)) {
      base = defaultSuffix
      output = candidate(base)
    }
    // Replacing is the user's choice for *existing* files, never for an input of this run.
    if replace && !protected.contains(identity(of: output)) { return output }

    var counter = 2
    while FileManager.default.fileExists(atPath: output.path)
      || protected.contains(identity(of: output))
    {
      output = candidate("\(base) \(counter)")
      counter += 1
    }
    return output
  }

  /// Accepts files and folders; folders are searched (one level deep and below) for PDFs.
  public static func expand(_ url: URL) -> [URL] {
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    guard isDirectory else {
      return url.pathExtension.lowercased() == "pdf" ? [url] : []
    }
    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    let contents = enumerator?.allObjects as? [URL] ?? []
    return contents.filter { $0.pathExtension.lowercased() == "pdf" }.sorted {
      $0.path < $1.path
    }
  }

  /// Two URLs name the same file if they resolve to the same path.
  private static func identity(of url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }
}
