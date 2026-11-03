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

    func testImportedFoldersSeparateFilesAndOpenNestedTracks() {
        launchWithFolders()
        let musicFolder = app.buttons["folderRow_Music Folder"]
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["folderRow_Other Folder"].exists)
        XCTAssertTrue(app.buttons["folderRow_Empty Folder"].exists)
        XCTAssertTrue(app.buttons["audioRow_UI Test.m4a"].exists)
        XCTAssertFalse(app.buttons["audioRow_Folder Track.m4a"].exists)
        XCTAssertFalse(app.buttons["audioRow_Nested Track.m4a"].exists)
        XCTAssertFalse(app.buttons["audioRow_Other Track.m4a"].exists)
        capture("05-folder-library")

        musicFolder.tap()
        let nestedTrack = app.buttons["audioRow_Nested Track.m4a"]
        XCTAssertTrue(nestedTrack.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["audioRow_Folder Track.m4a"].exists)
        XCTAssertFalse(app.buttons["audioRow_UI Test.m4a"].exists)
        XCTAssertFalse(app.buttons["audioRow_Other Track.m4a"].exists)
        capture("06-folder-contents")
        nestedTrack.tap()
        XCTAssertTrue(app.navigationBars["Edit tags"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nested Track.m4a"].exists)
        app.navigationBars["Edit tags"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(nestedTrack.waitForExistence(timeout: 3))
        app.navigationBars["Music Folder"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["audioRow_UI Test.m4a"].exists)
    }

    func testEmptyImportedFolderCanBeOpenedAndReturnedFrom() {
        launchWithFolders()
        let emptyFolder = app.buttons["folderRow_Empty Folder"]
        XCTAssertTrue(emptyFolder.waitForExistence(timeout: 15))
        emptyFolder.tap()
        let emptyState = app.descendants(matching: .any).matching(identifier: "folderEmptyState").firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["audioRow_UI Test.m4a"].exists)
        app.navigationBars["Empty Folder"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(emptyFolder.waitForExistence(timeout: 3))
    }

    func testFolderSelectionAndReviewStayWithinTheFolder() {
        launchWithFolders()
        editTrack("UI Test.m4a", prefix: "Standalone ")
        let musicFolder = app.buttons["folderRow_Music Folder"]
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 5))
        musicFolder.tap()
        editTrack("Folder Track.m4a", prefix: "Folder ")

        let select = app.buttons["librarySelectButton"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let selectedCount = app.staticTexts["selectedCountLabel"]
        XCTAssertEqual(selectedCount.label, "0 selected")
        app.buttons["selectAllButton"].tap()
        XCTAssertEqual(selectedCount.label, "2 selected")
        let review = app.buttons["reviewButton"]
        XCTAssertEqual(review.label, "Review 1")
        review.tap()
        let save = app.buttons["confirmSaveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "Save 1 file")
        XCTAssertTrue(app.staticTexts["Folder Track.m4a"].exists)
        XCTAssertFalse(app.staticTexts["UI Test.m4a"].exists)
        XCTAssertFalse(app.staticTexts["Other Track.m4a"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        app.navigationBars["Music Folder"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["reviewButton"].label, "Review 2")
        app.buttons["librarySelectButton"].tap()
        XCTAssertEqual(selectedCount.label, "0 selected")
        app.buttons["selectAllButton"].tap()
        XCTAssertEqual(selectedCount.label, "4 selected")
    }

    func testBatchRemovalCanBeCancelledThenRemovesAllSelectedLibraryFiles() {
        launchWithFolders()
        let musicFolder = app.buttons["folderRow_Music Folder"]
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 15))
        let remove = app.buttons["batchRemoveButton"]
        XCTAssertFalse(remove.exists)

        app.buttons["librarySelectButton"].tap()
        let selectedCount = app.staticTexts["selectedCountLabel"]
        XCTAssertEqual(selectedCount.label, "0 selected")
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(remove.isEnabled)
        let selectAll = app.buttons["selectAllButton"]
        selectAll.tap()
        XCTAssertEqual(selectedCount.label, "4 selected")
        XCTAssertTrue(remove.isEnabled)
        capture("07-batch-removal-selection")
        remove.tap()
        let confirm = app.buttons["confirmRemoveButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Remove 4 selected files?"].exists)
        capture("08-batch-removal-confirmation")
        app.buttons["Cancel"].tap()

        XCTAssertEqual(selectedCount.label, "4 selected")
        XCTAssertTrue(app.buttons["audioRow_UI Test.m4a"].exists)
        selectAll.tap()
        XCTAssertEqual(selectedCount.label, "0 selected")
        XCTAssertFalse(remove.isEnabled)
        selectAll.tap()
        XCTAssertEqual(selectedCount.label, "4 selected")
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertFalse(app.buttons["audioRow_UI Test.m4a"].exists)
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(selectedCount.exists)
        XCTAssertTrue(app.buttons["folderRow_Empty Folder"].exists)
        for name in ["Music Folder", "Other Folder"] {
            let folder = app.buttons["folderRow_\(name)"]
            XCTAssertTrue(folder.waitForExistence(timeout: 3))
            folder.tap()
            let emptyState = app.descendants(matching: .any).matching(identifier: "folderEmptyState").firstMatch
            XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["librarySelectButton"].exists)
            app.navigationBars[name].buttons.element(boundBy: 0).tap()
        }
    }

    func testBatchRemovalInFolderOnlyRemovesSelectedFiles() {
        launchWithFolders()
        let musicFolder = app.buttons["folderRow_Music Folder"]
        XCTAssertTrue(musicFolder.waitForExistence(timeout: 15))
        musicFolder.tap()
        let firstTrack = app.buttons["audioRow_Folder Track.m4a"]
        let nestedTrack = app.buttons["audioRow_Nested Track.m4a"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        let remove = app.buttons["batchRemoveButton"]
        XCTAssertFalse(remove.exists)
        let select = app.buttons["librarySelectButton"]
        select.tap()
        XCTAssertFalse(remove.isEnabled)
        firstTrack.tap()
        let selectedCount = app.staticTexts["selectedCountLabel"]
        XCTAssertEqual(selectedCount.label, "1 selected")
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        let confirm = app.buttons["confirmRemoveButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertTrue(nestedTrack.waitForExistence(timeout: 3))
        XCTAssertFalse(firstTrack.exists)
        XCTAssertEqual(select.label, "Select")
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(selectedCount.exists)
        select.tap()
        XCTAssertEqual(selectedCount.label, "0 selected")
        app.buttons["selectAllButton"].tap()
        XCTAssertEqual(selectedCount.label, "1 selected")
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let emptyState = app.descendants(matching: .any).matching(identifier: "folderEmptyState").firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertFalse(nestedTrack.exists)
        app.navigationBars["Music Folder"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["audioRow_UI Test.m4a"].waitForExistence(timeout: 3))
        XCTAssertTrue(musicFolder.exists)
        XCTAssertTrue(app.buttons["folderRow_Empty Folder"].exists)
        app.buttons["folderRow_Other Folder"].tap()
        XCTAssertTrue(app.buttons["audioRow_Other Track.m4a"].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
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

    func testSelectedReleaseCoverRequiresReviewThenSavesAndRestores() {
        app.terminate()
        app.launchArguments += ["--ui-testing-with-audio", "--ui-testing-with-cover"]
        app.launch()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.tap()
        let candidate = app.buttons["metadataCandidate_ui-cover-release"]
        for _ in 0..<6 where !candidate.isHittable { app.swipeUp() }
        XCTAssertTrue(candidate.isHittable)
        candidate.tap()
        let review = app.buttons["trackReviewButton"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: review)
        waitForExpectations(timeout: 10)
        review.tap()
        let newCover = app.buttons["draftArtworkPreview"]
        XCTAssertTrue(newCover.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No original cover"].exists)
        capture("04-cover-review")
        newCover.tap()
        let done = app.buttons["artworkPreviewDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        XCTAssertTrue(review.isEnabled, "Cancelling review must leave a pending draft")
        review.tap()
        app.buttons["confirmSaveButton"].tap()
        expectation(for: NSPredicate(format: "exists == true AND enabled == false"), evaluatedWith: review)
        waitForExpectations(timeout: 15)
        app.navigationBars["Edit tags"].buttons.element(boundBy: 0).tap()
        app.buttons["settingsButton"].tap()
        app.buttons["backupHistoryButton"].tap()
        let restore = app.buttons["Restore original"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.buttons["confirmRestoreButton"].tap()
        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 15))
        app.navigationBars["Undo changes"].buttons.element(boundBy: 0).tap()
        app.buttons["settingsDoneButton"].tap()
        audio.tap()
        let noCover = app.staticTexts["No embedded cover"]
        for _ in 0..<5 where !noCover.isHittable { app.swipeUp() }
        XCTAssertTrue(noCover.exists)
        XCTAssertFalse(review.isEnabled)
    }

    private func launchWithAudio() {
        app.terminate()
        app.launchArguments.append("--ui-testing-with-audio")
        app.launch()
    }

    private func launchWithFolders() {
        app.terminate()
        app.launchArguments.append("--ui-testing-with-folders")
        app.launch()
    }

    private func editTrack(_ fileName: String, prefix: String) {
        let audio = app.buttons["audioRow_\(fileName)"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        audio.tap()
        let title = app.descendants(matching: .any).matching(identifier: "tag_title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(prefix)
        app.navigationBars["Edit tags"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(audio.waitForExistence(timeout: 3))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
