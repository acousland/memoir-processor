import AppKit
import SwiftUI

/// The Thread palette follows the Mac's appearance, including the reading surface.
enum ThreadTheme {
    static let ink = color(0x4B343B, dark: 0xEEE0E6)
    static let muted = color(0x8D707C, dark: 0xBEA4B1)
    static let accent = color(0x965772, dark: 0xD599B3)
    static let paper = color(0xFFFAFB, dark: 0x292129)
    static let canvas = color(0xF8EEF0, dark: 0x211B22)
    static let line = color(0xEFDEE4, dark: 0x4B3845)
    static let selection = color(0xF4E6EC, dark: 0x49303E)
    static let windowColor = native(0xFFFAFB, dark: 0x292129)

    private static func color(_ light: UInt32, dark: UInt32) -> Color { Color(nsColor: native(light, dark: dark)) }
    private static func native(_ light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        }
    }
}

struct ThreadPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(25).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThreadTheme.paper, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(ThreadTheme.line, lineWidth: 1) }
    }
}
