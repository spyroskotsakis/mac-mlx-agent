import Foundation
import Vision
import ImageIO

func ocr(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
    var lines: [String] = []
    let req = VNRecognizeTextRequest { request, _ in
        guard let obs = request.results as? [VNRecognizedTextObservation] else { return }
        for o in obs {
            if let c = o.topCandidates(1).first {
                lines.append(c.string)
            }
        }
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    try? handler.perform([req])
    return lines.joined(separator: "\n")
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
let files = (try? fm.contentsOfDirectory(atPath: dir))?
    .filter { $0.hasSuffix(".jpg") }
    .sorted() ?? []
for f in files {
    let text = ocr(dir + "/" + f)
    print("=== \(f) ===")
    if !text.isEmpty { print(text) }
    fflush(stdout)
}
