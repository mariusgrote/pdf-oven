# PDF Oven

A small native macOS app that "bakes" PDFs: every page is re-drawn into a fresh PDF, so
annotations (highlights, notes, ink, stamps, form fields) become part of the page content
and can no longer be selected, moved, or edited.

It can also extract the image files stored inside a PDF, including images used by stamp
annotations and image file attachments.

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
- Use the Extract Images toolbar button or press ⌘E to write images to `name-images/`.
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

## Extract images from the command line

```sh
swift run PDFOvenCLI extract [--out DIR] [--min-size 32] [--no-dedupe] \
  [--no-markup] file.pdf ...
```

The extractor keeps stored JPEG and JPEG 2000 bytes when possible and reconstructs other
pixel data as PNG. By default it deduplicates repeated images and drops images smaller than
32 pixels in either direction or 1 KB after encoding.

It includes page image XObjects, stamp appearances, image file attachments, and images in the
document's embedded-file name tree. Inline images inside page content (`BI … ID … EI`) are not
supported. Ink, highlights, squares, text annotations, and other non-image markup produce no
output.

Every path is checked before anything is written: one that does not exist, a file that is not
a PDF, or a folder holding no PDFs ends the call with exit status 2 and no output at all, so a
mistyped argument cannot leave a half-finished run behind. A PDF that exists but cannot be
opened is a failure of the run, not of the call: the other inputs are still extracted and the
exit status is 1.

## Contributing

CI builds the app on every pull request. The code follows swift-format's default style
(2-space indent), so `swift format --in-place --recursive Sources Tools` before pushing
keeps diffs clean; there is no config file and no formatting gate in CI.

## Releases

Tag a commit `v*` — by pushing the tag, or by publishing a release in the GitHub UI, which
creates it. Either way CI builds the app, stamps the tag into the bundle as
`CFBundleShortVersionString` (so it shows in About PDF Oven and in Settings), and attaches
`PDF-Oven-<tag>.zip` for Apple Silicon and `PDF-Oven-<tag>-intel.zip` for Intel Macs to the
release, creating it if it does not exist yet:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Local builds stamp `git describe` instead, so a dev build reads e.g. `0.1.0-3-gabc1234`.
Override with `VERSION=1.2.3 ./build.sh`.

The build is ad-hoc signed, not notarized, so the first launch needs a right-click → Open.

## License

MIT — see [LICENSE](LICENSE).
