import XCTest

/// Drives the shipping iPhone app against a real Mac sync server: pastes a
/// pairing ticket into Settings, pairs over pinned TLS, and reads back the
/// mirrored Calls list.
///
/// This is a harness test, not a hermetic one. It is skipped unless
/// `CALLNOTES_SYNC_TICKET` carries the QR payload of a Mac that is listening,
/// the same way the Core harness suites are gated on `CALLNOTES_HARNESS`.
final class PhoneSyncUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPairingAMacMirrorsItsCallsIncludingOneWithNoCounterpartyName() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let ticket = environment["CALLNOTES_SYNC_TICKET"], !ticket.isEmpty else {
            throw XCTSkip("Set CALLNOTES_SYNC_TICKET to a live Mac's QR pairing payload to run this.")
        }

        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let payloadField = app.textFields["Pairing QR payload"]
        XCTAssertTrue(payloadField.waitForExistence(timeout: 10))
        payloadField.tap()
        // The trailing return resigns the keyboard, which otherwise covers the
        // tab bar this test taps next.
        payloadField.typeText(ticket + "\n")
        app.buttons["Pair"].firstMatch.tap()

        // Form rows expose their label and value as one accessibility element.
        let connected = app.staticTexts["Status, Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 20), "The phone never reported a paired Mac.")
        attach(app.screenshot(), named: "settings-paired")

        app.tabBars.buttons["Calls"].tap()
        // A recording shared with an empty Contact field must read as "Call",
        // never as a blank headline.
        let unnamed = app.staticTexts["Call"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 20), "The mirrored call with no counterparty name never appeared.")
        XCTAssertTrue(app.staticTexts["Priya Shah"].waitForExistence(timeout: 10))
        attach(app.screenshot(), named: "calls-mirrored")

        unnamed.tap()
        // Each turn reads as "<speaker>: <text>"; the far side keeps a
        // per-call Speaker N label when no profile claims it.
        XCTAssertTrue(app.staticTexts["Me: Thanks for making time today."].waitForExistence(timeout: 20))
        let farSide = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Speaker 2: '")).firstMatch
        XCTAssertTrue(farSide.waitForExistence(timeout: 10), "The far side never got a per-call speaker label.")
        attach(app.screenshot(), named: "call-detail-unnamed")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
