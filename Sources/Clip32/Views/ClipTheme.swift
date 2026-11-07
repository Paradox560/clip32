import AppKit
import SwiftUI

enum ClipTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.64, green: 0.84, blue: 0.69, alpha: 1)
        }
        return NSColor(srgbRed: 0.14, green: 0.43, blue: 0.29, alpha: 1)
    })
}
