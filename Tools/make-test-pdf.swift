import Foundation
import PDFOvenFixtures

// Writes the PDF the image-extraction tests assert against, for looking at by hand:
//     swift run MakeTestPDF fixture.pdf
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test-images.pdf"
let url = URL(fileURLWithPath: path)
do {
  try FixturePDF.data().write(to: url)
  print("Wrote \(url.path)")
} catch {
  FileHandle.standardError.write(Data("make-test-pdf: \(error.localizedDescription)\n".utf8))
  exit(1)
}
