import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum Preference {
    static let suffix = "suffix"
    static let destinationFolder = "destinationFolderPath"
    static let replaceExisting = "replaceExisting"
    static let revealWhenDone = "revealWhenDone"

    static var defaultSuffix: String { "-baked" }

    static func register() {
        UserDefaults.standard.register(defaults: [
            suffix: defaultSuffix,
            replaceExisting: false,
            revealWhenDone: false,
        ])
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
    @Published private(set) var isBaking = false

    func clear() {
        guard !isBaking else { return }
        items.removeAll()
    }

    /// Accepts files and folders; folders are searched (one level deep and below) for PDFs.
    func add(_ urls: [URL]) {
        let pdfs = urls.flatMap(Self.expand(_:)).filter { url in
            !items.contains { $0.input == url }
        }
        guard !pdfs.isEmpty else { return }
        items.append(contentsOf: pdfs.map { BakeItem(input: $0) })
        Task { await bakePending() }
    }

    private func bakePending() async {
        guard !isBaking else { return }
        isBaking = true
        defer { isBaking = false }

        let defaults = UserDefaults.standard
        let suffix = defaults.string(forKey: Preference.suffix) ?? Preference.defaultSuffix
        let replace = defaults.bool(forKey: Preference.replaceExisting)
        let folder = defaults.string(forKey: Preference.destinationFolder).map { URL(fileURLWithPath: $0) }

        while let index = items.firstIndex(where: { $0.status == .waiting }) {
            let input = items[index].input
            items[index].status = .baking
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    let output = Self.destination(for: input, suffix: suffix, folder: folder, replace: replace)
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
                if defaults.bool(forKey: Preference.revealWhenDone) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failure(let error):
                items[current].status = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func expand(_ url: URL) -> [URL] {
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
        return contents.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.path < $1.path }
    }

    nonisolated static func destination(for input: URL, suffix: String, folder: URL?, replace: Bool) -> URL {
        let directory = folder ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty && folder == nil ? Preference.defaultSuffix : trimmed
        var candidate = directory.appendingPathComponent(stem + base).appendingPathExtension("pdf")
        guard !replace else { return candidate }

        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)\(base) \(counter)")
                .appendingPathExtension("pdf")
            counter += 1
        }
        return candidate
    }
}
