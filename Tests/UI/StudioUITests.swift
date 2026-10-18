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
        XCTAssertTrue(app.otherElements["studio-test"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["drawing-Solstice"].waitForExistence(timeout: 30), app.debugDescription)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStudioFlowAndScreenshots() {
        screenshot("01-Gallery")
        app.buttons["drawing-Solstice"].tap()
        XCTAssertTrue(app.buttons["panel-Symmetry"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        XCTAssertFalse(app.buttons["redo"].isEnabled)
        screenshot("02-Canvas")

        app.buttons["panel-Symmetry"].tap()
        XCTAssertTrue(app.buttons["symmetry-16"].waitForExistence(timeout: 5))
        app.buttons["symmetry-16"].tap()
        XCTAssertTrue(app.staticTexts["16 copies"].exists)
        screenshot("03-Symmetry")
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
        screenshot("07-Gallery-portrait")
        app.textFields["gallerySearch"].tap()
        app.textFields["gallerySearch"].typeText("Quiet")
        XCTAssertTrue(app.buttons["drawing-Quiet orbit"].exists)
        XCTAssertFalse(app.buttons["drawing-Solstice"].exists)
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
