import Foundation

// The command line front end is not built yet; the library it will drive is.
// Installed as `pdfoven`; the target keeps a distinct name because macOS filesystems
// are case-insensitive and `.build/release/pdfoven` would collide with the app binary.
FileHandle.standardError.write(Data("pdfoven: no commands yet\n".utf8))
exit(2)
