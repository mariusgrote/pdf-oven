# PDF Oven

A small native macOS app that "bakes" PDF annotations into page content so they can no
longer be selected, moved, or edited.

It can also remove annotations without baking them, or extract the image files stored
inside a PDF, including images used by stamp annotations and image file attachments.

## Build

```sh
./build.sh
open "build/PDF Oven.app"
```

`build.sh` builds for the host architecture by default; pass `--arch arm64` or
`--arch x86_64` to cross-compile for the other one.

The app icon is generated, not hand-drawn: `swift Tools/make-icon.swift` redraws
`Packaging/AppIcon.icns` from CoreGraphics primitives. Only rerun it if you change the design.

Building requires the Swift toolchain from Xcode or the Command Line Tools plus CMake; no
Xcode project is needed. The script assembles `build/PDF Oven.app` and ad-hoc signs it. Move
it to `/Applications` if you want it permanently.

The build downloads pinned qpdf and libjpeg-turbo source archives, verifies their checksums,
and compiles a self-contained qpdf helper. The helper and dependency licenses are included in
the app bundle. People using PDF Oven do not need qpdf, Homebrew, or another runtime install.

## Use

- Select Bake, Remove, or Extract Images in the main window, then drag PDFs (or folders of PDFs) onto it,
  or press ⌘O. The selected action also applies to files opened through Finder.
- For Bake and Remove, the two checkboxes independently keep hyperlinks clickable and form fields editable.
  Keeping forms retains their values. Each import keeps the choices from when it was added.
- Bake saves each file next to the original as `name-baked.pdf`.
- Remove saves `name_cleaned.pdf`. It discards markup and, unless their checkboxes are
  enabled, hyperlinks and form fields with their values.
- Extract Images writes images to `name-images/`. Press ⌘E to extract directly regardless
  of the selected action.
- Use "Extraction options" below the drop zone to set the minimum width/height and file size, combine duplicates,
  or include images from annotations and attachments. Set either minimum to 0 to disable its filter.
  Each import keeps the options from when it was added. Results report duplicate, too-small,
  and unreadable images separately. Unreadable images produce a warning with expandable details.
- Overlapping folder/file selections and symlinks to the same PDF are imported once per action.
  Completed files can be imported again. Outputs in the current list receive distinct names,
  even when replacement is enabled. Clear the list to start a new run with fresh reservations.
- Options below the drop zone show the controls for the selected action: baking method and
  filename suffix for Bake, link/form preservation and lossless compression for Bake and Remove,
  and image filters for Extract Images.
- ⌘, opens Settings for the shared output folder, replacement policy, and Finder reveal.
  These preferences apply to every action.
- The app registers as a PDF handler, so you can also drop files on its Dock icon or use
  "Open With".

## How the baking works

The compatibility redraw remains the default. `Baker.bake` opens the document with PDFKit
and draws each page into a new `CGPDFContext`. `PDFPage.draw(with:to:)` renders annotation
appearances along with page content, and the new document contains no editable markup or form fields. Hyperlinks remain clickable
by default. Turn off "Keep hyperlinks clickable" in the main window to discard them.
Enable "Keep form fields editable" to retain the form widgets and their values. In that
case, baking uses qpdf regardless of the selected baking method.

The baking method menu also offers two methods for comparing output on a particular document:

- Native macOS burn-in uses PDFKit's annotation burn-in write option.
- qpdf flattening inserts existing annotation appearance streams into the page content without
  redrawing the full page.

Both methods preserve vector content in the synthetic test fixture without introducing image
objects. That result is evidence for the fixture, not a guarantee for every PDF producer or
annotation type. PDF Oven rejects visible markup annotations that have no selected appearance stream
and forms marked with stale appearances rather than risk dropping or baking the wrong content.
For a missing annotation appearance, the file's queue row offers a choice to continue the
selected method with possible omission or retry that file with Compatibility redraw.
If the user continues the selected method, the result names the page to inspect.
An unmarked stale appearance cannot be detected reliably from the PDF structure.

Lossless qpdf compression is independent of the baking method. qpdf recompresses Flate streams
at compression level 9 and generates object streams. It never converts or downsamples images.
PDF Oven keeps the compressed copy only when it is smaller.
If compression fails, PDF Oven saves the baked file without compression and shows the error
beside the result.

The following behavior describes the compatibility redraw:

- Text stays real text (searchable and selectable), including text inside note annotations.
- Page rotation and offset crop boxes are baked into the output geometry.
- Document title/author/subject/creator/keywords are carried over.
- Not carried over: outlines/bookmarks, embedded attachments, and unfilled form
  fields (fields are baked in at their current values). Password-protected files are skipped
  with an error rather than being unlocked.

Originals are never modified.

## Remove annotations

Remove Annotations discards annotations instead of painting them into the page. It uses
qpdf to remove page annotation entries and, when forms are not kept, the document's form
tree while retaining the existing page content streams, images, geometry, and other document
content. Already baked markup is part of the page content and cannot be removed by this action.

The action uses the configured output folder, replacement policy, lossless compression,
and Finder reveal setting. Its suffix is always `_cleaned`; the custom baking suffix applies
only to baking. The checkboxes preserve links and editable forms independently for both actions.
Originals remain protected, and existing output names are numbered when replacement is
disabled. The result is validated for page count and absence of unwanted annotations and
form structures before it is saved.

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
exit status is 1. An extraction with unreadable image occurrences also exits with status 1,
retains the images it could write, and reports the missing occurrences on stderr. The summary
separates duplicates, size-filtered images, and unreadable images. Same-named inputs from different
folders receive separate output folders within the call, including with `--replace`.

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
