import XCTest

final class MusTagUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    func testEmptyLibraryOffersFilesAndFolderImport() {
        let add = app.buttons["addAudioButton"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reviewButton"].exists)
        add.tap()
        XCTAssertTrue(app.buttons["chooseFilesButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["chooseFolderButton"].exists)
    }

    func testMissingKeyCanBeConfiguredWithoutNetwork() {
        app.buttons["settingsButton"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Key required")
        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("local-ui-test-key")
        app.buttons["saveKeyButton"].tap()
        expectation(for: NSPredicate(format: "value == %@", "Configured"), evaluatedWith: status)
        waitForExpectations(timeout: 3)
        app.buttons["settingsDoneButton"].tap()
        XCTAssertTrue(app.buttons["addAudioButton"].firstMatch.waitForExistence(timeout: 3))
    }

    func testLicensesAreReadableOffline() {
        app.buttons["settingsButton"].tap()
        let licenses = app.buttons["licensesButton"]
        if !licenses.isHittable { app.swipeUp() }
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()
        app.buttons["taglibLicenseButton"].tap()
        let text = app.staticTexts["licenseText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertTrue(text.label.localizedCaseInsensitiveContains("Mozilla Public License"))
    }

    func testManualEditReviewSaveAndRestoreRealAudio() throws {
        launchWithAudio()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        capture("01-library")
        audio.tap()
        let title = app.descendants(matching: .any).matching(identifier: "tag_title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        capture("02-editor")
        title.tap()
        let originalTitle = "Original title"
        let insertedText = "Edited "
        title.typeText(insertedText)
        let editedTitle = try XCTUnwrap(title.value as? String)
        XCTAssertNotEqual(editedTitle, originalTitle)
        XCTAssertTrue(editedTitle.contains(insertedText))
        XCTAssertTrue(editedTitle.contains(originalTitle))
        XCTAssertEqual(editedTitle.count, originalTitle.count + insertedText.count)
        app.buttons["trackReviewButton"].tap()
        XCTAssertTrue(app.buttons["confirmSaveButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Original title"].exists)
        XCTAssertTrue(app.staticTexts[editedTitle].exists)
        capture("03-review")
        app.buttons["confirmSaveButton"].tap()
        let review = app.buttons["trackReviewButton"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == false"), evaluatedWith: review)
        waitForExpectations(timeout: 15)
        app.navigationBars["Edit tags"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts[editedTitle].waitForExistence(timeout: 3))
        app.buttons["settingsButton"].tap()
        app.buttons["backupHistoryButton"].tap()
        let restore = app.buttons["Restore original"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.buttons["confirmRestoreButton"].tap()
        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 15))
        app.navigationBars["Undo changes"].buttons.element(boundBy: 0).tap()
        app.buttons["settingsDoneButton"].tap()
        XCTAssertTrue(app.staticTexts["Original title"].waitForExistence(timeout: 5))
    }

    func testIdentifyWithoutKeyOpensSettingsFromEditor() {
        launchWithAudio()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.tap()
        app.buttons["trackIdentifyButton"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Key required")
        XCTAssertTrue(app.secureTextFields["apiKeyField"].exists)
    }

    private func launchWithAudio() {
        app.terminate()
        app.launchArguments.append("--ui-testing-with-audio")
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
