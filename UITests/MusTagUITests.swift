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
        let welcome = app.descendants(matching: .any).matching(identifier: "welcomeScreen").firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 8))
        let tabs = app.tabBars.buttons
        XCTAssertEqual(tabs.allElementsBoundByIndex.map(\.label), ["Home", "Connections", "Settings"])
        XCTAssertTrue(tabs["Home"].isSelected)
        tabs["Connections"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabs["Connections"].isSelected)
        tabs["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabs["Settings"].isSelected)
        tabs["Home"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 3))
        XCTAssertTrue(tabs["Home"].isSelected)
        let brand = app.descendants(matching: .any).matching(identifier: "welcomeBrandLabel").firstMatch
        XCTAssertTrue(brand.exists)
        XCTAssertEqual(brand.label, "MusTag")
        capture("welcome-brand-header")
        let add = app.buttons["addAudioButton"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reviewButton"].exists)

        let faq = app.buttons["welcomeFAQButton"]
        XCTAssertTrue(faq.exists)
        faq.tap()
        XCTAssertTrue(app.navigationBars["Good to know"].waitForExistence(timeout: 3))
        let faqContent = app.descendants(matching: .any).matching(identifier: "welcomeFAQContent").firstMatch
        XCTAssertTrue(faqContent.exists)
        app.buttons["welcomeFAQDoneButton"].tap()
        XCTAssertTrue(faq.waitForExistence(timeout: 3))

        add.tap()
        XCTAssertTrue(app.buttons["chooseFilesButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["chooseFolderButton"].exists)
    }

    func testConnectionsGroupsAndImportEntrypoints() {
        app.tabBars.buttons["Connections"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 3))
        let list = app.collectionViews.firstMatch
        for title in ["Local", "NAS & Servers"] {
            let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
            XCTAssertTrue(header.exists, title)
        }
        capture("13-connections")

        for identifier in ["connectionFilesButton", "connectionFolderButton"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable, identifier)
            button.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 8))
            cancel.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
            waitForExpectations(timeout: 3)
            XCTAssertTrue(app.navigationBars["Connections"].exists)
            XCTAssertTrue(app.tabBars.buttons["Connections"].isSelected)
        }

        for (service, title) in [("smb", "SMB"), ("ftp", "FTP"),
                                 ("webDAV", "WebDAV"), ("navidrome", "Navidrome")] {
            let row = app.buttons["connectionService_\(service)"]
            for _ in 0..<4 where !row.isHittable { list.swipeUp() }
            XCTAssertTrue(row.isHittable, service)
            row.tap()
            let detail = app.descendants(matching: .any)
                .matching(identifier: "connectionServiceDetail_\(service)").firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 3), service)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@", "Connections are not available yet.")).firstMatch.exists)
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 3))
            XCTAssertTrue(row.exists, service)
        }

        let cloud = app.buttons["connectionCloudButton"]
        for _ in 0..<4 where !cloud.isHittable { list.swipeUp() }
        XCTAssertTrue(cloud.isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Cloud storage")).firstMatch.exists)
        capture("14-connections-cloud-storage")
        cloud.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.navigationBars["Connections"].exists)
        XCTAssertTrue(app.tabBars.buttons["Connections"].isSelected)
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
        app.tabBars.buttons["Settings"].tap()
        selectRecognitionService("AcoustID")
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Key required")
        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.exists)
        field.tap()
        let keyDraft = "local-ui-test-key"
        field.typeText(keyDraft)
        dismissFormKeyboard()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["addAudioButton"].firstMatch.waitForExistence(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual((field.value as? String)?.count, keyDraft.count,
                       "Switching tabs must keep the unsaved key input")
        XCTAssertEqual(status.value as? String, "Key required")
        XCTAssertTrue(app.buttons["saveKeyButton"].exists)
        app.buttons["saveKeyButton"].tap()
        expectation(for: NSPredicate(format: "value == %@", "Configured"), evaluatedWith: status)
        waitForExpectations(timeout: 3)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["addAudioButton"].firstMatch.waitForExistence(timeout: 3))
    }

    func testLicensesAreReadableOffline() {
        app.tabBars.buttons["Settings"].tap()
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
        dismissFormKeyboard()
        app.tabBars.buttons["Connections"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Edit tags"].waitForExistence(timeout: 3))
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.value as? String, editedTitle,
                       "Switching tabs must keep the current editor and its draft")
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
        app.tabBars.buttons["Settings"].tap()
        app.buttons["backupHistoryButton"].tap()
        let restore = app.buttons["Restore original"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.buttons["confirmRestoreButton"].tap()
        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 15))
        app.navigationBars["Undo changes"].buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Original title"].waitForExistence(timeout: 5))
    }

    func testIdentifyWithoutKeyOpensSettingsFromEditor() {
        launchWithAudio()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        selectRecognitionService("AcoustID")
        let licenses = app.buttons["licensesButton"]
        if !licenses.isHittable { app.swipeUp() }
        licenses.tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 3),
                      "Normal tab switching must preserve the settings navigation stack")
        app.tabBars.buttons["Home"].tap()
        audio.tap()
        app.buttons["trackIdentifyButton"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Settings"].exists,
                      "Missing credentials must open the settings root, not its previous subpage")
        XCTAssertEqual(status.value as? String, "Key required")
        XCTAssertTrue(app.secureTextFields["apiKeyField"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Edit tags"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UI Test.m4a"].exists)
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    func testRecognitionServiceSwitchShowsOnlyTheRequiredCredentials() {
        app.tabBars.buttons["Settings"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "No API key needed")
        XCTAssertFalse(app.secureTextFields["apiKeyField"].exists)

        selectRecognitionService("AcoustID")
        XCTAssertEqual(status.value as? String, "Key required")
        XCTAssertTrue(app.secureTextFields["apiKeyField"].exists)
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Key required")

        selectRecognitionService("ShazamKit")
        XCTAssertEqual(status.value as? String, "No API key needed")
        XCTAssertFalse(app.secureTextFields["apiKeyField"].exists)
        app.tabBars.buttons["Home"].tap()
    }

    func testShazamRecognizesWithoutKeyAndKeepsResultsInDraftUntilSaved() {
        app.terminate()
        app.launchArguments += ["--ui-testing-with-audio", "--ui-testing-shazam"]
        app.launch()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "recognitionStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "No API key needed")
        XCTAssertFalse(app.secureTextFields["apiKeyField"].exists)
        app.tabBars.buttons["Home"].tap()

        app.buttons["identifyButton"].tap()
        let notice = app.alerts["Notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Added to drafts: 1")).firstMatch.exists)
        notice.buttons["OK"].tap()
        let review = app.buttons["reviewButton"]
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.buttons["confirmSaveButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original title"].exists)
        XCTAssertTrue(app.staticTexts["Shazam matched title"].exists)
        let reviewLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "reviewDraftAppleMusicLink_")).firstMatch
        XCTAssertTrue(reviewLink.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(review.isEnabled)

        audio.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "draftAppleMusicLink").firstMatch.waitForExistence(timeout: 5))
        let details = app.buttons["shazamMetadataDetailsButton"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        let detailsDone = app.buttons["shazamMetadataDetailsDoneButton"]
        XCTAssertTrue(detailsDone.waitForExistence(timeout: 5))
        for (field, value) in [("subtitle", "Shazam supplementary details"),
                               ("isrc", "USAAA2600001"), ("appleMusicID", "456")] {
            let row = app.descendants(matching: .any).matching(identifier: "shazamMetadata_\(field)").firstMatch
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, field)
            XCTAssertEqual(row.value as? String, value, field)
        }
        detailsDone.tap()
        for (field, value) in [("title", "Shazam matched title"), ("artist", "Shazam matched artist"),
                               ("album", "Test album"), ("albumArtist", "Album artist"),
                               ("year", "1998"), ("trackNumber", "7"), ("discNumber", "2"), ("genre", "Pop")] {
            let input = app.descendants(matching: .any).matching(identifier: "tag_\(field)").firstMatch
            for _ in 0..<5 where !input.exists { app.swipeUp() }
            XCTAssertTrue(input.exists, field)
            XCTAssertEqual(input.value as? String, value, field)
        }
        let candidate = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "metadataCandidate_", "Test album")).firstMatch
        for _ in 0..<7 where !candidate.isHittable { app.swipeUp() }
        XCTAssertTrue(candidate.isHittable)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "metadataCandidate_")).count, 1,
                       "The Shazam match and its Apple Music details must share one candidate")
        XCTAssertTrue(candidate.isSelected)
        XCTAssertTrue(candidate.label.contains("Apple Music"))
        XCTAssertTrue(candidate.label.contains("Year 1998"))
        XCTAssertTrue(candidate.label.contains("Disc 2"))
        XCTAssertTrue(candidate.label.contains("Track 7"))
        XCTAssertFalse(candidate.label.contains("%"), "Shazam must not be presented as an AcoustID similarity score")
        let appleMusicLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleMusicLink_")).firstMatch
        XCTAssertTrue(appleMusicLink.exists)
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleMusicLink_")).count, 1)
        XCTAssertEqual(candidate.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleMusicLink_")).count, 0,
            "The Apple Music link must be separate from applying a candidate")
        capture("11-shazam-candidate")
        app.buttons["trackReviewButton"].tap()
        XCTAssertTrue(app.buttons["confirmSaveButton"].waitForExistence(timeout: 5))
        app.buttons["confirmSaveButton"].tap()
        let trackReview = app.buttons["trackReviewButton"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == false"), evaluatedWith: trackReview)
        waitForExpectations(timeout: 15)
    }

    func testShazamAlbumConflictHasOneCandidateAndCanRestoreOriginalAlbumInformation() {
        app.terminate()
        app.launchArguments += ["--ui-testing-with-audio", "--ui-testing-shazam", "--ui-testing-shazam-album-conflict"]
        app.launch()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        app.buttons["identifyButton"].tap()
        let notice = app.alerts["Notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        notice.buttons["OK"].tap()
        audio.tap()
        XCTAssertTrue(app.navigationBars["Edit tags"].waitForExistence(timeout: 5))
        assertEditorTags([("album", "Test album"), ("year", ""), ("trackNumber", ""), ("discNumber", "")])

        let candidateID = "shazam:appleMusic:456"
        let candidate = app.descendants(matching: .any).matching(identifier: "metadataCandidate_\(candidateID)").firstMatch
        let useAppleMusic = app.buttons["useAppleMusicAlbum_\(candidateID)"]
        let keepOriginal = app.buttons["keepOriginalAlbum_\(candidateID)"]
        for _ in 0..<8 where !useAppleMusic.isHittable { app.swipeUp() }
        XCTAssertTrue(useAppleMusic.isHittable)
        XCTAssertTrue(keepOriginal.exists)
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "metadataCandidate_")).count, 1)
        XCTAssertTrue(candidate.label.contains("Original album: Test album"))
        XCTAssertTrue(candidate.label.contains("Apple Music album: Different catalog album"))
        XCTAssertTrue(candidate.label.contains("choose album information"))
        XCTAssertFalse(useAppleMusic.isSelected)
        XCTAssertFalse(keepOriginal.isSelected)
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "appleMusicLink_")).count, 1)
        capture("12-shazam-album-conflict")

        useAppleMusic.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: useAppleMusic)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(keepOriginal.isSelected)
        assertEditorTags([("album", "Different catalog album"), ("albumArtist", "Album artist"),
                          ("year", "1998"), ("trackNumber", "7"), ("discNumber", "2")])

        for _ in 0..<8 where !keepOriginal.isHittable { app.swipeUp() }
        XCTAssertTrue(keepOriginal.isHittable)
        keepOriginal.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: keepOriginal)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(useAppleMusic.isSelected)
        XCTAssertTrue(candidate.label.contains("Original album information kept"))
        assertEditorTags([("title", "Shazam matched title"), ("album", "Test album"), ("albumArtist", ""),
                          ("year", ""), ("trackNumber", ""), ("discNumber", "")])
        XCTAssertTrue(app.buttons["trackReviewButton"].isEnabled, "Both choices must remain draft changes until review and save")
    }

    func testAutomaticMatchingRanksCandidatesAndKeepsDraftUntilReviewSave() {
        app.terminate()
        app.launchArguments += ["--ui-testing-with-audio", "--ui-testing-auto-match"]
        app.launch()
        let audio = app.buttons["audioRow_UI Test.m4a"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        let batchReview = app.buttons["reviewButton"]
        XCTAssertFalse(batchReview.isEnabled)
        app.buttons["identifyButton"].tap()

        let notice = app.alerts["Notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Added to drafts: 1")).firstMatch.exists)
        notice.buttons["OK"].tap()
        XCTAssertTrue(batchReview.isEnabled)
        XCTAssertEqual(batchReview.label, "Review 1")
        batchReview.tap()
        XCTAssertTrue(app.buttons["confirmSaveButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["draftArtworkPreview"].exists, "AcoustID does not supply album artwork")
        XCTAssertTrue(app.staticTexts["Original title"].exists)
        XCTAssertTrue(app.staticTexts["Matched title"].exists)
        capture("09-auto-match-review")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(batchReview.waitForExistence(timeout: 3))
        XCTAssertTrue(batchReview.isEnabled, "Cancelling review must keep the automatic draft")

        audio.tap()
        let highID = "metadataCandidate_10000000-0000-0000-0000-000000000001"
        let lowID = "metadataCandidate_10000000-0000-0000-0000-000000000002"
        let high = app.buttons[highID]
        let low = app.buttons[lowID]
        for _ in 0..<6 where !low.isHittable { app.swipeUp() }
        XCTAssertTrue(high.exists)
        XCTAssertTrue(low.exists)
        XCTAssertTrue(high.label.contains("97.00%"))
        XCTAssertTrue(low.label.contains("89.00%"))
        XCTAssertTrue(high.isSelected, "The highest similarity must be selected by default")
        XCTAssertFalse(low.isSelected)
        let rankedIDs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "metadataCandidate_")).allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(rankedIDs, [highID, lowID])
        capture("10-auto-match-candidates")

        let review = app.buttons["trackReviewButton"]
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.buttons["confirmSaveButton"].waitForExistence(timeout: 5))
        app.buttons["confirmSaveButton"].tap()
        expectation(for: NSPredicate(format: "exists == true AND enabled == false"), evaluatedWith: review)
        waitForExpectations(timeout: 15)
        app.navigationBars["Edit tags"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Matched title"].waitForExistence(timeout: 5))
        XCTAssertFalse(batchReview.isEnabled)
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
        app.tabBars.buttons["Settings"].tap()
        app.buttons["backupHistoryButton"].tap()
        let restore = app.buttons["Restore original"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.buttons["confirmRestoreButton"].tap()
        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 15))
        app.navigationBars["Undo changes"].buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Home"].tap()
        audio.tap()
        let noCover = app.staticTexts["No embedded cover"]
        for _ in 0..<5 where !noCover.isHittable { app.swipeUp() }
        XCTAssertTrue(noCover.exists)
        XCTAssertFalse(review.isEnabled)
    }

    private func dismissFormKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let done = app.buttons["dismissKeyboardButton"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        waitForExpectations(timeout: 3)
    }

    private func launchWithAudio() {
        app.terminate()
        app.launchArguments.append("--ui-testing-with-audio")
        app.launch()
    }

    private func selectRecognitionService(_ name: String) {
        let picker = app.segmentedControls["recognitionProviderPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons[name].tap()
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

    private func assertEditorTags(_ values: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        let title = app.descendants(matching: .any).matching(identifier: "tag_title").firstMatch
        for _ in 0..<8 where !title.isHittable { app.swipeDown() }
        for (field, expected) in values {
            let input = app.descendants(matching: .any).matching(identifier: "tag_\(field)").firstMatch
            for _ in 0..<6 where !input.isHittable { app.swipeUp() }
            XCTAssertTrue(input.exists, field, file: file, line: line)
            let value = input.value as? String ?? ""
            if expected.isEmpty {
                // Empty text fields may expose their placeholder as the accessibility value.
                XCTAssertTrue(value.isEmpty || value == input.label, "\(field): \(value)", file: file, line: line)
            } else {
                XCTAssertEqual(value, expected, field, file: file, line: line)
            }
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
