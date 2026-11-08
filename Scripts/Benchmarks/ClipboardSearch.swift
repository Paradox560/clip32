// Synthetic RTF search/presentation benchmark; never reads real clipboard data.
// Run from the repository root:
// swiftc -O -module-cache-path .build/module-cache \
//   Sources/ClipCore/ClipboardEntry.swift Sources/ClipCore/ClipboardSearchIndex.swift \
//   Scripts/Benchmarks/ClipboardSearch.swift -framework AppKit -o /tmp/clip32-search-benchmark
// /tmp/clip32-search-benchmark
import AppKit
import Foundation

@main
struct ClipboardSearchBenchmark {
    static func main() throws {
        let entries: [ClipboardEntry] = try (0..<256).map { number in
            let text = String(repeating: "ordinary copied text ", count: 1_500) + " final needle \(number)"
            let attributed = NSAttributedString(string: text)
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return ClipboardEntry(items: [ClipboardItem(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: data)
            ])])
        }
        var checksum = 0
        let queries = ["needle", "final", "needle", "final", "needle"]
        let baseline = measure {
            for query in queries {
                checksum += entries.filter { entry in
                    autoreleasepool { entry.searchableText.localizedCaseInsensitiveContains(query) }
                }.count
            }
        } / Double(queries.count)
        let index = ClipboardSearchIndex()
        var results: [ClipboardEntry] = []
        let cold = measure { results = index.search(entries, query: "needle", filter: .all) ?? [] }
        checksum += results.count
        let warm = measure {
            for query in queries {
                results = index.search(entries, query: query, filter: .all) ?? []
                checksum += results.count
            }
        } / Double(queries.count)
        let navigation = measure {
            for index in 0..<10_000 { checksum += results[index % results.count].id.uuidString.count }
        } / 10_000

        let visible = Array(entries.prefix(12))
        let presentationBaseline = measure {
            for _ in 0..<5 {
                for entry in visible { autoreleasepool { checksum += entry.title.count + entry.preview.count } }
            }
        } / 5
        let presentations = ClipboardPresentationCache()
        let presentationCold = measure {
            for entry in visible { autoreleasepool { checksum += presentations.presentation(for: entry).title.count } }
        }
        let presentationWarm = measure {
            for _ in 0..<5 {
                for entry in visible { checksum += presentations.presentation(for: entry).title.count }
            }
        } / 5
        print("entries=\(entries.count) rtf_payload_bytes=\(entries.reduce(0) { $0 + $1.byteCount })")
        print("baseline_scan_mean_ms=\(baseline) cold_indexed_scan_ms=\(cold) warm_indexed_scan_mean_ms=\(warm)")
        print("materialized_navigation_mean_ms=\(navigation) charged_text_cache_bytes=\(index.cachedByteCount)")
        print("visible_rows=\(visible.count) baseline_presentation_mean_ms=\(presentationBaseline) cold_presentation_ms=\(presentationCold) cached_presentation_mean_ms=\(presentationWarm)")
        print("checksum=\(checksum)")
    }

    private static func measure(_ action: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        action()
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }
}
