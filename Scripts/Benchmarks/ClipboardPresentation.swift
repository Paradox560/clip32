// Synthetic display-metadata benchmark. Never reads the system clipboard or history.
// Run from the repository root:
// swiftc -O -module-cache-path .build/module-cache \
//   Sources/ClipCore/ClipboardEntry.swift Scripts/Benchmarks/ClipboardPresentation.swift \
//   -framework AppKit -o /tmp/clip32-presentation-benchmark
// /tmp/clip32-presentation-benchmark
import AppKit
import Foundation

@main
struct ClipboardPresentationBenchmark {
    static func main() {
        for bytes in [32_768, 262_144, 2_097_152] {
            for multiline in [false, true] {
                let seed = multiline ? String(repeating: "A", count: 99) + "\n" : "A"
                let text = String(String(repeating: seed, count: bytes / seed.utf8.count + 1).prefix(bytes))
                let entry = ClipboardEntry(items: [ClipboardItem(representations: [
                    ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
                ])])
                var titleMilliseconds: [Double] = []
                var previewMilliseconds: [Double] = []
                var displayedCharacters = 0
                for _ in 0..<5 {
                    let start = CFAbsoluteTimeGetCurrent()
                    displayedCharacters += entry.title.count
                    let afterTitle = CFAbsoluteTimeGetCurrent()
                    displayedCharacters += entry.preview.count
                    let afterPreview = CFAbsoluteTimeGetCurrent()
                    titleMilliseconds.append((afterTitle - start) * 1_000)
                    previewMilliseconds.append((afterPreview - afterTitle) * 1_000)
                }
                let titleMean = titleMilliseconds.reduce(0, +) / Double(titleMilliseconds.count)
                let previewMean = previewMilliseconds.reduce(0, +) / Double(previewMilliseconds.count)
                print("bytes=\(bytes) multiline=\(multiline) title_mean_ms=\(titleMean) preview_mean_ms=\(previewMean) characters=\(displayedCharacters)")
            }
        }
    }
}
