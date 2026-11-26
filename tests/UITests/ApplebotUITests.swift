import XCTest

/// End-to-end smoke tests that drive the real app against `MockEngine` (`-UITestMockEngine`),
/// so they run on any simulator without Apple Intelligence. Executed by the macOS CI job.
final class ApplebotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITestMockEngine"]
        app.launch()
    }

    func testTabsAreReachable() {
        // Companion IA: Chat · Library · Health · Stocks · You
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Health"].tap()
        XCTAssertTrue(app.navigationBars["Health"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Stocks"].tap()
        XCTAssertTrue(app.navigationBars["Stocks"].waitForExistence(timeout: 5))
        app.tabBars.buttons["You"].tap()
        XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 5))
        let model = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Apple Intelligence'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "You tab should describe the on-device model")
    }

    func testStocksTabEnablePrompt() {
        app.tabBars.buttons["Stocks"].tap()
        XCTAssertTrue(app.navigationBars["Stocks"].waitForExistence(timeout: 10))
        let enable = app.descendants(matching: .any)["stocks-enable"]
        if enable.waitForExistence(timeout: 5) {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Not financial advice'")).firstMatch
                    .waitForExistence(timeout: 5)
            )
            let enableButton = app.buttons["Enable Stocks"]
            if enableButton.waitForExistence(timeout: 3) {
                enableButton.tap()
            }
        }
        // After enable (or if already on), dashboard or empty watchlist should be reachable.
        XCTAssertTrue(
            app.staticTexts["Watchlist"].waitForExistence(timeout: 8)
                || app.descendants(matching: .any)["stocks-movers"].waitForExistence(timeout: 8)
                || app.descendants(matching: .any)["stocks-enable"].waitForExistence(timeout: 2),
            "Stocks tab should show enable prompt or dashboard"
        )
    }

    func testHealthTabConnectsAndAddsMedication() {
        app.tabBars.buttons["Health"].tap()
        XCTAssertTrue(app.navigationBars["Health"].waitForExistence(timeout: 10))

        let connect = app.descendants(matching: .any)["health-connect"]
        if connect.waitForExistence(timeout: 5) {
            // Hero primary button label.
            let connectButton = app.buttons["Connect Apple Health"]
            XCTAssertTrue(connectButton.waitForExistence(timeout: 3))
            connectButton.tap()
        }

        XCTAssertTrue(
            app.staticTexts["Wellness score"].waitForExistence(timeout: 10)
                || app.descendants(matching: .any)["wellness-score"].waitForExistence(timeout: 10),
            "after connecting, wellness score should appear"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Not medical advice'")).firstMatch
                .waitForExistence(timeout: 5)
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["health-week-trend"].waitForExistence(timeout: 5)
                || app.staticTexts["Last 7 days"].waitForExistence(timeout: 5),
            "7-day wellness trend should appear after connect"
        )
        XCTAssertTrue(app.buttons["ask-health-score"].waitForExistence(timeout: 5))

        app.buttons["add-medication"].tap()
        let name = app.textFields["medication-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Metformin")
        if app.switches["medication-reminders-toggle"].waitForExistence(timeout: 3) {
            app.switches["medication-reminders-toggle"].tap()
            let times = app.textFields["medication-reminder-times"]
            if times.waitForExistence(timeout: 2) {
                times.tap()
                times.typeText("08:00")
            }
        }
        app.buttons["save-medication"].tap()
        XCTAssertTrue(app.staticTexts["Metformin"].waitForExistence(timeout: 5))

        app.buttons["ask-health-score"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.textFields["message-field"].waitForExistence(timeout: 8)
                || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'wellness'")).firstMatch
                    .waitForExistence(timeout: 8),
            "Ask from Health should open Chat with a prompt"
        )
    }

    func testThemeSettingsListsOptionsAndSelectsMidnight() {
        app.tabBars.buttons["You"].tap()
        let link = app.buttons["theme-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["theme-system"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["theme-daylight"].exists)
        XCTAssertTrue(app.buttons["theme-midnight"].exists)
        XCTAssertTrue(app.buttons["theme-ocean"].exists)
        XCTAssertTrue(app.buttons["theme-forest"].exists)
        XCTAssertTrue(app.buttons["theme-highContrast"].exists)

        app.buttons["theme-midnight"].tap()
        // Selected checkmark is exposed as accessibility label on the row.
        XCTAssertTrue(app.buttons["theme-midnight"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Midnight"].waitForExistence(timeout: 5),
                      "You tab should show the selected theme name")
    }

    func testChatSendsMessageAndShowsStreamedReply() {
        startNewChat()
        send("Hello offline world")

        XCTAssertTrue(app.staticTexts["Hello offline world"].waitForExistence(timeout: 5))
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mock reply'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "assistant reply should stream in")
    }

    func testPastedDocumentAppearsAndGroundsAnswer() {
        // Add a document by pasting text.
        app.tabBars.buttons["Library"].tap()
        app.buttons["add-document"].tap()
        app.buttons["Paste text"].tap()

        let titleField = app.textFields["e.g. Meeting notes"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Router notes")
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("Hold the reset button for ten seconds to restore factory settings.")
        app.navigationBars["Paste text"].buttons["Add"].tap()

        XCTAssertTrue(app.staticTexts["Router notes"].waitForExistence(timeout: 10), "document should be listed")

        // Ask a question; with documents present the chat should use them (mock engine echoes the question).
        app.tabBars.buttons["Chat"].tap()
        startNewChat()
        send("How do I reset the router?")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mock reply'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        // The "Why this answer?" affordance proves retrieval ran and sources were stored.
        XCTAssertTrue(app.buttons["Why this answer?"].waitForExistence(timeout: 5))
        app.buttons["Why this answer?"].tap()
        XCTAssertTrue(app.staticTexts["Router notes"].waitForExistence(timeout: 5)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'reset button'")).firstMatch.exists)
    }

    func testNewChatInsideConversationStartsBrandNewConversation() {
        startNewChat()
        send("First topic about routers")
        let firstReply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mock reply'")).firstMatch
        XCTAssertTrue(firstReply.waitForExistence(timeout: 10))

        // New chat from inside the conversation: previous messages must not carry over.
        let inlineNew = app.buttons["new-chat-inline"]
        XCTAssertTrue(inlineNew.isEnabled, "new chat should be available once the chat has messages")
        inlineNew.tap()

        XCTAssertTrue(app.textFields["message-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["First topic about routers"].exists, "new chat must start empty")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mock reply'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["new-chat-inline"].isEnabled, "an empty chat is already new")

        // Back to the list: the old chat is kept, the empty draft is not.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["First topic about routers"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells.count, 1, "only the chat with messages should be listed")
    }

    func testDeleteChatFromInsideConversation() {
        startNewChat()
        send("Disposable chat about orchids")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mock reply'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))

        let options = app.buttons["chat-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()

        let deleteItem = app.buttons["Delete Chat"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.tap()

        let alert = app.alerts["Delete this conversation?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()

        // Returns to chat home; the deleted conversation must not remain.
        XCTAssertTrue(
            app.buttons["Start chatting"].waitForExistence(timeout: 5)
                || app.navigationBars["Applebot"].waitForExistence(timeout: 5),
            "deleting should pop back to the chat list"
        )
        XCTAssertFalse(app.staticTexts["Disposable chat about orchids"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["message-field"].exists, "the open chat screen should be gone")
    }

    func testAttachDocumentFromChatPlusMenu() {
        startNewChat()

        app.buttons["attach"].tap()
        app.buttons["Paste text…"].tap()

        let titleField = app.textFields["e.g. Meeting notes"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Attached manual")
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("Hold the reset button for ten seconds to restore factory settings.")
        app.navigationBars["Paste text"].buttons["Add"].tap()

        // The attachment appears as a chip in this chat.
        let chip = app.descendants(matching: .any).matching(identifier: "attachment-chip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "attached document should appear above the message box")
        XCTAssertTrue(chip.label.contains("Attached manual") || app.staticTexts["Attached manual"].exists
                      || app.buttons["Attached manual"].exists)

        // Asking now uses the attached document.
        send("How do I reset it?")
        XCTAssertTrue(app.buttons["Why this answer?"].waitForExistence(timeout: 10))
    }

    func testPlusMenuOffersAttachOptions() {
        startNewChat()
        app.buttons["attach"].tap()
        XCTAssertTrue(app.buttons["Speak…"].waitForExistence(timeout: 5), "voice entry should be in the + menu")
        XCTAssertTrue(app.buttons["Files…"].exists)
        XCTAssertTrue(app.buttons["Photos…"].exists)
        XCTAssertTrue(app.buttons["Paste text…"].exists)
    }

    /// Taps the mic twice (start + stop). Fails if the app process dies (the previous installTap crash).
    func testMicButtonDoesNotCrash() {
        startNewChat()

        let mic = app.buttons["mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "mic button should be visible next to Send")

        // Dismiss system permission sheets if they appear so the tap is not blocked.
        addUIInterruptionMonitor(withDescription: "voice permissions") { alert in
            let allow = alert.buttons["Allow"].exists ? alert.buttons["Allow"]
                : (alert.buttons["OK"].exists ? alert.buttons["OK"] : alert.buttons.firstMatch)
            if allow.exists { allow.tap(); return true }
            return false
        }

        mic.tap()
        // Nudge the run loop so interruption monitors can fire.
        app.tap()

        // Give recording a moment; the old bug aborted immediately on tap.
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        XCTAssertTrue(app.textFields["message-field"].exists, "app must still be alive after starting the mic")
        XCTAssertTrue(app.buttons["mic"].exists, "mic control must still be in the hierarchy")

        // Second tap stops recording / transcribes (may show an alert if nothing was heard).
        if app.buttons["mic"].exists {
            app.buttons["mic"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }

        // Dismiss our in-app Voice alert if present.
        if app.alerts["Voice"].waitForExistence(timeout: 3) {
            app.alerts["Voice"].buttons["OK"].tap()
        }

        XCTAssertTrue(app.textFields["message-field"].waitForExistence(timeout: 5),
                      "app must still be alive after stopping the mic")
        XCTAssertEqual(app.state, .runningForeground, "Applebot should not have crashed")
    }

    func testConnectorsScreenListsServicesAndConnectsCalendar() {
        app.tabBars.buttons["You"].tap()
        let link = app.buttons["connectors-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Calendar"].exists)
        XCTAssertTrue(app.staticTexts["Gmail"].exists)

        // Gmail has no Google client ID in the mock build, so it explains what is missing instead of offering Connect.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'GOOGLE_CLIENT_ID'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["connect-gmail"].exists)

        // Calendar connects (the mock provider grants access) and then offers an on/off switch, off by default.
        let connect = app.buttons["connect-calendar"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let toggle = app.switches["toggle-calendar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "connecting switches the connector on")
        // A Form toggle row reports the whole row as the switch; tap where the control actually is.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        // The switch updates after an async registry round trip, so wait for it instead of reading immediately.
        let paused = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        wait(for: [paused], timeout: 5)
    }

    // MARK: Connector actions need approval

    /// Relaunches with a scripted model that proposes adding a calendar event, with Calendar connected.
    private func launchProposingAnEvent() {
        app.terminate()
        app.launchArguments = ["-UITestMockEngine", "-UITestToolDemo"]
        app.launch()

        app.tabBars.buttons["You"].tap()
        XCTAssertTrue(app.buttons["connectors-link"].waitForExistence(timeout: 10))
        app.buttons["connectors-link"].tap()
        let connect = app.buttons["connect-calendar"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.switches["toggle-calendar"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap() // back to Settings
        app.tabBars.buttons["Chat"].tap()
        startNewChat()
        send("Add lunch with Sam tomorrow at 12:30")
    }

    func testCalendarEventWaitsForApprovalThenIsAdded() {
        launchProposingAnEvent()

        // The sheet shows exactly what will be added, and nothing has happened yet.
        let detail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Lunch with Sam'")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "the approval sheet should show the event")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Cafe Roma'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Added to the calendar'")).firstMatch.exists)

        app.buttons["approval-approve"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Added to the calendar'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "approving should run the tool and report the result")
        XCTAssertTrue(app.staticTexts["tools-used"].waitForExistence(timeout: 5)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Adding a calendar event'")).firstMatch.exists,
                      "the reply should say which connector action was used")
    }

    func testNoticeExplainsWhyConnectorsAreIdleWhileSearchingDocuments() {
        // A document in the library makes chats answer from documents, which pauses connector tools.
        app.tabBars.buttons["Library"].tap()
        app.buttons["add-document"].tap()
        app.buttons["Paste text"].tap()
        let titleField = app.textFields["e.g. Meeting notes"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Notes")
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("Remember to water the plants on Friday.")
        app.navigationBars["Paste text"].buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Notes"].waitForExistence(timeout: 10))

        app.tabBars.buttons["You"].tap()
        app.buttons["connectors-link"].tap()
        let connect = app.buttons["connect-calendar"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.switches["toggle-calendar"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Chat"].tap()
        startNewChat()
        let notice = app.descendants(matching: .any)["connector-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the chat should say connectors are paused while documents are used")
        app.buttons["use-connectors-instead"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        wait(for: [gone], timeout: 5)
    }

    func testDecliningTheApprovalDoesNothing() {
        launchProposingAnEvent()

        XCTAssertTrue(app.buttons["approval-decline"].waitForExistence(timeout: 15))
        app.buttons["approval-decline"].tap()

        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'declined'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "the model should be told the user declined")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Added to the calendar'")).firstMatch.exists)
    }

    // MARK: Helpers

    private func startNewChat() {
        let chats = app.tabBars.buttons["Chat"]
        XCTAssertTrue(chats.waitForExistence(timeout: 10))
        let newChat = app.buttons["new-chat"].exists ? app.buttons["new-chat"] : app.buttons["Start chatting"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(app.textFields["message-field"].waitForExistence(timeout: 5))
    }

    private func send(_ text: String) {
        let field = app.textFields["message-field"]
        field.tap()
        field.typeText(text)
        app.buttons["send"].tap()
    }
}
