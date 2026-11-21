import XCTest

/// Drives the Nogrammerly keyboard in the app's "Try it" field. The keyboard must be enabled on the
/// simulator first (Settings → General → Keyboard → Keyboards, or the AppleKeyboards default).
final class KeyboardUITests: XCTestCase {
    @MainActor
    func testKeyboardTypesAndFixesTypo() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Keyboard"].firstMatch.tap()
        let field = app.descendants(matching: .any)["tryField"].firstMatch
        // The "Try it" row is at the bottom of a lazy list, so it only exists once scrolled to.
        for _ in 0..<4 where !field.exists { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        // Empty field: auto-capitalisation shows capitals, then lower case after one letter.
        let capitalT = app.buttons["T"]
        XCTAssertTrue(capitalT.waitForExistence(timeout: 10), "Nogrammerly keyboard did not appear")
        capitalT.tap()
        app.buttons["e"].tap()
        app.buttons["h"].tap()
        app.buttons["Space"].tap()
        XCTAssertEqual(field.value as? String, "Teh ")

        let chip = app.buttons["Change Teh to The"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "No suggestion chip for the typo")
        save("keyboard-light")
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        save("keyboard-dark")
        XCUIDevice.shared.appearance = .light

        chip.tap()
        let fixed = NSPredicate(format: "value == %@", "The ")
        wait(for: [expectation(for: fixed, evaluatedWith: field)], timeout: 5)
    }

    /// Screenshots go to $SCREENSHOT_DIR when set, so they can be reviewed outside Xcode.
    @MainActor
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
