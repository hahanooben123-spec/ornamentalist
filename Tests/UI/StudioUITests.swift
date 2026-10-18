import XCTest

final class StudioUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["--ui-showcase"]
        app.launchEnvironment["ORNAMENTALIST_UI_TEST"] = "showcase"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["studio-test"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        screenshot("00-Launch")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNormalLaunchWithoutShowcase() {
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["studio"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["newDrawing"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createDrawing"].waitForExistence(timeout: 5))
        app.buttons["createDrawing"].tap()
        XCTAssertTrue(app.buttons["panel-Symmetry"].waitForExistence(timeout: 15), app.debugDescription)
        screenshot("10-Normal-launch-canvas")
        app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["newDrawing"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["drawing-Untitled Drawing"].firstMatch.waitForExistence(timeout: 15))
    }

    func testMirrorAndLayerManagementSurviveReopening() {
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.textFields["drawingName"].waitForExistence(timeout: 5))
        app.textFields["drawingName"].tap(); app.textFields["drawingName"].typeText("Mirror layers")
        app.buttons["createDrawing"].tap()
        XCTAssertTrue(app.buttons["panel-Symmetry"].waitForExistence(timeout: 15))
        app.buttons["panel-Symmetry"].tap()
        let mirror = app.switches["mirrorToggle"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 5))
        if !mirror.isHittable { app.scrollViews.firstMatch.swipeUp() }
        mirror.tap(); XCTAssertEqual(mirror.value as? String, "1")
        screenshot("11-Mirror")
        app.buttons["closePanel"].tap()
        app.buttons["panel-Layers"].tap()
        XCTAssertTrue(app.buttons["addLayer"].waitForExistence(timeout: 5))
        app.buttons["addLayer"].tap()
        XCTAssertTrue(app.buttons["select-layer-Layer 2"].isSelected)
        app.buttons["layer-options-Layer 2"].tap(); app.buttons["Rename"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "Details")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["select-layer-Details"].waitForExistence(timeout: 5))
        app.buttons["visibility-Details"].tap()
        XCTAssertEqual(app.buttons["visibility-Details"].value as? String, "Hidden")
        app.buttons["visibility-Details"].tap()
        app.buttons["lock-Details"].tap()
        XCTAssertEqual(app.buttons["lock-Details"].value as? String, "Locked")
        app.buttons["lock-Details"].tap()
        app.buttons["layer-options-Details"].tap(); app.buttons["Move down"].tap()
        screenshot("12-Layers")
        app.buttons["layer-options-Details"].tap(); app.buttons["Delete layer"].tap()
        app.alerts.buttons["Delete layer"].tap()
        XCTAssertFalse(app.buttons["select-layer-Details"].exists)
        app.buttons["closePanel"].tap(); app.buttons["undo"].tap()
        app.buttons["panel-Layers"].tap()
        XCTAssertTrue(app.buttons["select-layer-Details"].waitForExistence(timeout: 5))
        app.buttons["closePanel"].tap(); app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-Mirror layers"].waitForExistence(timeout: 15))
        app.buttons["drawing-Mirror layers"].tap()
        XCTAssertTrue(app.buttons["panel-Layers"].waitForExistence(timeout: 10))
        app.buttons["panel-Layers"].tap()
        XCTAssertTrue(app.buttons["select-layer-Details"].isSelected)
        app.buttons["closePanel"].tap(); app.buttons["panel-Symmetry"].tap()
        XCTAssertEqual(app.switches["mirrorToggle"].value as? String, "1")
    }

    func testStudioFlowAndScreenshots() {
        XCTAssertTrue(app.buttons["drawing-Solstice"].waitForExistence(timeout: 30), app.debugDescription)
        screenshot("01-Gallery")
        app.buttons["drawing-Solstice"].tap()
        XCTAssertTrue(app.buttons["panel-Symmetry"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        XCTAssertFalse(app.buttons["redo"].isEnabled)
        screenshot("02-Canvas")

        app.buttons["panel-Symmetry"].tap()
        XCTAssertTrue(app.buttons["symmetry-16"].waitForExistence(timeout: 5))
        app.buttons["symmetry-16"].tap()
        screenshot("03-Symmetry")
        XCTAssertTrue(app.buttons["symmetry-16"].isSelected)
        let copies = app.descendants(matching: .any)["symmetryCopies"].firstMatch
        XCTAssertTrue((copies.value as? String)?.contains("16") == true)
        app.buttons["closePanel"].tap()
        app.buttons["undo"].tap()
        XCTAssertTrue(app.buttons["redo"].isEnabled)
        app.buttons["redo"].tap()
        app.buttons["enterZen"].tap()
        XCTAssertTrue(app.buttons["leaveZen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["panel-Symmetry"].exists)
        screenshot("04-Focus")
        app.buttons["leaveZen"].tap()

        app.buttons["panel-Fineliner"].tap()
        XCTAssertTrue(app.sliders["Line width"].waitForExistence(timeout: 5))
        screenshot("05-Fineliner")
        app.buttons["closePanel"].tap()
        app.buttons["panel-Canvas"].tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        app.buttons["closePanel"].tap()
        app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-Solstice"].waitForExistence(timeout: 20))
        screenshot("06-Gallery-dark")

        XCUIDevice.shared.orientation = .portrait
        app.textFields["gallerySearch"].tap()
        app.textFields["gallerySearch"].typeText("Quiet")
        XCTAssertTrue(app.buttons["drawing-Quiet orbit"].exists)
        XCTAssertFalse(app.buttons["drawing-Solstice"].exists)
        // The keyboard interaction also waits for the rotation animation to settle.
        screenshot("07-Gallery-portrait-search")
    }

    func testCreateNamedDrawing() {
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.textFields["drawingName"].waitForExistence(timeout: 5))
        screenshot("08-New-drawing")
        app.textFields["drawingName"].tap()
        app.textFields["drawingName"].typeText("My first ornament")
        app.buttons["createDrawing"].tap()
        XCTAssertTrue(app.buttons["gallery"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["My first ornament"].exists)
        app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-My first ornament"].waitForExistence(timeout: 15))
    }

    func testEmptyStudio() {
        app.terminate()
        app.launchArguments = ["--ui-showcase", "--ui-empty"]
        app.launchEnvironment["ORNAMENTALIST_UI_TEST"] = "empty"
        app.launch()
        XCTAssertTrue(app.staticTexts["It starts with a single line."].waitForExistence(timeout: 10))
        screenshot("09-Empty-studio")
        XCTAssertTrue(app.buttons["newDrawing"].firstMatch.isEnabled)
    }
}
