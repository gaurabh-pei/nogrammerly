import AppKit
import Testing
@testable import Nogrammerly

@MainActor
@Suite struct FillViewTests {
    /// Panel backgrounds must follow light/dark switches instead of keeping the colour from launch.
    @Test func backgroundFollowsAppearanceChanges() throws {
        let view = FillView(color: .controlBackgroundColor)
        view.frame = NSRect(x: 0, y: 0, width: 10, height: 10)

        view.appearance = NSAppearance(named: .aqua)
        view.updateLayer()
        let light = try #require(view.layer?.backgroundColor)

        view.appearance = NSAppearance(named: .darkAqua)
        view.updateLayer()
        let dark = try #require(view.layer?.backgroundColor)

        #expect(light != dark)
        #expect(light == NSAppearance(named: .aqua)!.resolve(NSColor.controlBackgroundColor))
    }
}

private extension NSAppearance {
    func resolve(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}
