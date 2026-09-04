# PDF Oven

A small native macOS app that "bakes" PDFs: every page is re-drawn into a fresh PDF, so
annotations (highlights, notes, ink, stamps, form fields) become part of the page content
and can no longer be selected, moved, or edited.

## Build

```sh
./build.sh
open "build/PDF Oven.app"
```

`build.sh` builds for the host architecture by default; pass `--arch arm64` or
`--arch x86_64` to cross-compile for the other one.

The app icon is generated, not hand-drawn: `swift Tools/make-icon.swift` redraws
`Packaging/AppIcon.icns` from CoreGraphics primitives. Only rerun it if you change the design.

Requires the Swift toolchain from Xcode or the Command Line Tools; no Xcode project needed.
The script assembles `build/PDF Oven.app` and ad-hoc signs it. Move it to `/Applications`
if you want it permanently.

## Use

- Drag PDFs (or folders of PDFs) onto the window, or press ⌘O.
- Each file is saved next to the original as `name-baked.pdf`.
- ⌘, opens Settings: filename suffix, a fixed output folder, whether to replace an existing
  file of the same name, and whether to reveal results in Finder.
- The app registers as a PDF handler, so you can also drop files on its Dock icon or use
  "Open With".

## How the baking works

`Baker.bake` opens the document with PDFKit and draws each page into a new `CGPDFContext`.
`PDFPage.draw(with:to:)` renders annotation appearances along with the page content, and the
new document is written from drawing commands only, so it contains no annotation objects.

- Text stays real text (searchable and selectable), including text inside note annotations.
- Page rotation and offset crop boxes are baked into the output geometry.
- Document title/author/subject/creator/keywords are carried over.
- Not carried over: outlines/bookmarks, links, embedded attachments, and unfilled form
  fields (fields are baked in at their current values). Password-protected files are skipped
  with an error rather than being unlocked.

Originals are never modified.

## Contributing

CI builds the app on every pull request. The code follows swift-format's default style
(2-space indent), so `swift format --in-place --recursive Sources Tools` before pushing
keeps diffs clean; there is no config file and no formatting gate in CI.

## Releases

Push a `v*` tag and CI builds the app, stamps the version into the bundle from the tag, and
attaches two builds to a GitHub release — `PDF-Oven-<tag>.zip` for Apple Silicon and
`PDF-Oven-<tag>-intel.zip` for Intel Macs:

```sh
git tag v0.1 && git push origin v0.1
```

The build is ad-hoc signed, not notarized, so the first launch needs a right-click → Open.

## License

MIT — see [LICENSE](LICENSE).
