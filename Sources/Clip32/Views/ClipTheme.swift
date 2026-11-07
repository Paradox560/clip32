import AppKit
import SwiftUI

enum ClipTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.72, green: 0.68, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.38, green: 0.34, blue: 0.79, alpha: 1)
    })
}
