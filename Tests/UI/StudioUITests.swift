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

    private func openLayersPanel() {
        let button = app.buttons["panel-Layers"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isSelected { button.tap() }
        XCTAssertTrue(app.buttons["addLayer"].waitForExistence(timeout: 5))
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

    func testSideControlsAndMultiFingerHistory() {
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createDrawing"].waitForExistence(timeout: 5))
        app.buttons["createDrawing"].tap()
        let size = app.sliders["railSize"], opacity = app.sliders["railOpacity"]
        XCTAssertTrue(size.waitForExistence(timeout: 15)); XCTAssertTrue(opacity.isHittable)
        size.adjust(toNormalizedSliderPosition: 0.55); opacity.adjust(toNormalizedSliderPosition: 0.3)
        let sizeValue = app.staticTexts["railSizeValue"].label
        let opacityValue = app.staticTexts["railOpacityValue"].label
        XCTAssertNotEqual(sizeValue, "5.0"); XCTAssertNotEqual(opacityValue, "100%")
        app.buttons["panel-Brushes"].tap()
        XCTAssertTrue(app.buttons["brush-brushPen"].waitForExistence(timeout: 5))
        app.buttons["brush-brushPen"].tap(); app.buttons["closePanel"].tap()
        XCTAssertNotEqual(app.staticTexts["railSizeValue"].label, sizeValue)
        app.buttons["panel-Brushes"].tap(); app.buttons["brush-fineliner"].tap(); app.buttons["closePanel"].tap()
        XCTAssertEqual(app.staticTexts["railSizeValue"].label, sizeValue)
        XCTAssertEqual(app.staticTexts["railOpacityValue"].label, opacityValue)
        let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
        let originalFrame = canvas.frame
        openLayersPanel(); app.buttons["addLayer"].tap()
        XCTAssertTrue(app.buttons["select-layer-Layer 2"].isSelected)
        app.buttons["visibility-Layer 2"].tap()
        XCTAssertEqual(app.buttons["visibility-Layer 2"].value as? String, "Hidden")
        app.buttons["visibility-Layer 2"].tap()
        screenshot("20-Side-controls-and-layers")
        app.buttons["closePanel"].tap()
        XCTAssertEqual(canvas.frame, originalFrame)
        app.buttons["panel-Canvas"].tap()
        let finger = app.switches["Draw with finger"]
        XCTAssertTrue(finger.waitForExistence(timeout: 5)); finger.tap()
        app.buttons["closePanel"].tap()
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate(format: "value == 'Strokes: 1'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        expectation(for: NSPredicate(format: "value == 'Strokes: 0'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        expectation(for: NSPredicate(format: "value == 'Strokes: 1'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        // Pinching is navigation and must neither add ink nor trigger Undo.
        canvas.pinch(withScale: 1.3, velocity: 1)
        XCTAssertEqual(canvas.value as? String, "Strokes: 1")
        app.buttons["tool-eyedropper"].tap()
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 2)
        expectation(for: NSPredicate(format: "value == 'Strokes: 0'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["tool-eyedropper"].isSelected)
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        expectation(for: NSPredicate(format: "value == 'Strokes: 1'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        app.buttons["tool-eyedropper"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.sliders["railSize"].waitForExistence(timeout: 5))
        openLayersPanel()
        XCTAssertTrue(app.buttons["visibility-Layer 2"].isHittable)
        screenshot("21-Portrait-side-controls")
    }

    func testEraserEyedropperDuplicateAndMergeFlow() {
        XCTAssertTrue(app.buttons["drawing-Solstice"].waitForExistence(timeout: 30))
        app.buttons["drawing-Solstice"].tap()
        XCTAssertTrue(app.buttons["tool-eraser"].waitForExistence(timeout: 15))
        app.buttons["tool-eraser"].tap(); XCTAssertTrue(app.buttons["tool-eraser"].isSelected)
        app.buttons["panel-Brushes"].tap()
        XCTAssertTrue(app.sliders["Eraser size"].waitForExistence(timeout: 5))
        app.segmentedControls["eraserEdge"].buttons["Soft"].tap()
        screenshot("17-Eraser-settings")
        app.buttons["returnToBrush"].tap(); app.buttons["closePanel"].tap()
        app.buttons["tool-eyedropper"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["eyedropperHint"].firstMatch.waitForExistence(timeout: 5))
        let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
        XCTAssertTrue(canvas.exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unselected = NSPredicate(format: "selected == false")
        expectation(for: unselected, evaluatedWith: app.buttons["tool-eyedropper"])
        waitForExpectations(timeout: 15)
        openLayersPanel()
        app.buttons["layer-options-Layer 1"].tap(); app.buttons["Duplicate layer"].tap()
        XCTAssertTrue(app.buttons["select-layer-Layer 1 copy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["select-layer-Layer 1 copy"].isSelected)
        screenshot("18-Layer-thumbnails-duplicate")
        app.buttons["layer-options-Layer 1 copy"].tap(); app.buttons["Merge down"].tap()
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: app.buttons["closePanel"])
        waitForExpectations(timeout: 20)
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["panel-Layers"])
        waitForExpectations(timeout: 20)
        openLayersPanel()
        XCTAssertTrue(app.buttons["select-layer-Layer 1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["select-layer-Layer 1 copy"].exists)
        screenshot("19-Merged-layer")
        app.buttons["closePanel"].tap(); app.buttons["undo"].tap()
        openLayersPanel()
        XCTAssertTrue(app.buttons["select-layer-Layer 1 copy"].waitForExistence(timeout: 10))
    }

    func testColorPickerLayerVisibilityAndOpacityPersist() {
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createDrawing"].waitForExistence(timeout: 5))
        app.buttons["createDrawing"].tap()
        XCTAssertTrue(app.buttons["panel-Colors"].waitForExistence(timeout: 15))
        app.buttons["panel-Colors"].tap()
        XCTAssertTrue(app.segmentedControls["colorMode"].waitForExistence(timeout: 5))
        screenshot("15-Color-disc")
        app.segmentedControls["colorMode"].buttons["Values"].tap()
        let field = app.textFields["colorHex"]
        if !field.isHittable { app.scrollViews.firstMatch.swipeUp() }
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "#327DD1\n")
        app.buttons["closePanel"].tap()
        XCTAssertEqual(app.buttons["panel-Colors"].value as? String, "#327DD1")
        openLayersPanel(); app.buttons["addLayer"].tap()
        let opacity = app.sliders["layerOpacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 5)); opacity.adjust(toNormalizedSliderPosition: 0.4)
        // Read the committed value after the final drag event and panel dismissal.
        app.buttons["closePanel"].tap(); openLayersPanel()
        let percentage = app.staticTexts["layerOpacityValue"].label
        XCTAssertNotEqual(percentage, "100%")
        app.buttons["visibility-Layer 2"].tap()
        XCTAssertEqual(app.buttons["visibility-Layer 2"].value as? String, "Hidden")
        screenshot("16-Layer-opacity-hidden")
        app.buttons["closePanel"].tap(); app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-Untitled Drawing"].waitForExistence(timeout: 15))
        app.buttons["drawing-Untitled Drawing"].tap()
        XCTAssertTrue(app.buttons["panel-Colors"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["panel-Colors"].value as? String, "#327DD1")
        openLayersPanel()
        XCTAssertEqual(app.staticTexts["layerOpacityValue"].label, percentage)
        XCTAssertEqual(app.buttons["visibility-Layer 2"].value as? String, "Hidden")
        app.buttons["visibility-Layer 2"].tap()
        XCTAssertEqual(app.buttons["visibility-Layer 2"].value as? String, "Visible")
        XCTAssertEqual(app.staticTexts["layerOpacityValue"].label, percentage)
    }

    func testBrushLibrarySelectionAndSettingsSurviveReopening() {
        app.buttons["newDrawing"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createDrawing"].waitForExistence(timeout: 5))
        app.buttons["createDrawing"].tap()
        XCTAssertTrue(app.buttons["panel-Brushes"].waitForExistence(timeout: 15))
        app.buttons["panel-Brushes"].tap()
        let families = app.segmentedControls["brushFamily"]
        XCTAssertTrue(families.waitForExistence(timeout: 5))
        families.buttons["Dots"].tap()
        let dots = app.buttons["brush-dotShader"]
        if !dots.isHittable { app.scrollViews.firstMatch.swipeUp() }
        dots.tap(); XCTAssertTrue(dots.isSelected)
        screenshot("13-Dot-brushes")
        app.scrollViews.firstMatch.swipeUp()
        let opacity = app.sliders["Brush opacity"]
        if !opacity.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(opacity.isHittable)
        opacity.adjust(toNormalizedSliderPosition: 0.35)
        app.buttons["closePanel"].tap(); app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-Untitled Drawing"].waitForExistence(timeout: 15))
        app.buttons["drawing-Untitled Drawing"].tap()
        XCTAssertTrue(app.buttons["panel-Brushes"].waitForExistence(timeout: 15))
        app.buttons["panel-Brushes"].tap()
        XCTAssertTrue(app.buttons["brush-dotShader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["brush-dotShader"].isSelected)
        families.buttons["Shading"].tap()
        app.buttons["brush-softShader"].tap()
        XCTAssertTrue(app.buttons["brush-softShader"].isSelected)
        screenshot("14-Soft-shading-brushes")
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
        openLayersPanel()
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
        openLayersPanel()
        XCTAssertTrue(app.buttons["select-layer-Details"].waitForExistence(timeout: 5))
        app.buttons["closePanel"].tap(); app.buttons["gallery"].tap()
        XCTAssertTrue(app.buttons["drawing-Mirror layers"].waitForExistence(timeout: 15))
        app.buttons["drawing-Mirror layers"].tap()
        XCTAssertTrue(app.buttons["panel-Layers"].waitForExistence(timeout: 10))
        openLayersPanel()
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

        app.buttons["panel-Brushes"].tap()
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
