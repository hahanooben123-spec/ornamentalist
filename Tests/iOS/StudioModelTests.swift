import XCTest
import UIKit
import MetalKit
@testable import Ornamentalist

@MainActor
final class StudioModelTests: XCTestCase {
    func testImportedImageTransformCancelApplyUndoAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80), format: format).image { output in
            UIColor.red.setFill(); output.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        }
        let repository = DocumentRepository(directory: folder)
        let model = StudioModel(repository: repository)
        await model.create(); await model.insertImage(try XCTUnwrap(image.pngData()))
        XCTAssertTrue(model.isTransforming); XCTAssertFalse(model.canDraw)
        XCTAssertEqual(model.document?.layers.count, 2)
        let original = try XCTUnwrap(model.document?.activeLayer?.raster)
        model.moveImage(by: Point(x: 100, y: 30)); model.scaleImage(by: 0.5); model.rotateImage(by: .pi / 2)
        XCTAssertEqual(model.document?.activeLayer?.raster, original)
        XCTAssertNotEqual(model.displayDocument?.activeLayer?.raster?.placement, original.placement)
        model.finishImageTransform(apply: false)
        XCTAssertEqual(model.document?.activeLayer?.raster, original)
        model.beginImageTransform(); model.moveImage(by: Point(x: 100, y: 30))
        model.scaleImage(by: 0.5); model.rotateImage(by: .pi / 2); model.flipImage(horizontal: true)
        model.finishImageTransform(apply: true)
        let transformed = try XCTUnwrap(model.document?.activeLayer?.raster)
        XCTAssertEqual(transformed.png, original.png)
        XCTAssertNotEqual(transformed.placement, original.placement)
        model.undo(); XCTAssertEqual(model.document?.activeLayer?.raster, original)
        model.redo(); XCTAssertEqual(model.document?.activeLayer?.raster, transformed)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let (reopened, _) = try await repository.open(try XCTUnwrap(model.document?.id))
        XCTAssertEqual(reopened.activeLayer?.raster, transformed)
    }

    func testLogoLookupWithoutResourcesReturnsNilInsteadOfCrashing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.ornamentalist.empty-logo", "CFBundlePackageType": "BNDL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: folder))
        XCTAssertNil(StudioBrandLogo.loadImage(in: bundle))
    }

    func testAllBrushPreferencesAndEraserSurviveRestartWithoutManualSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ornamentalist-all-brushes-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await model.create()
        var expected: [BrushPreset: InkBrush] = [:]
        for (index, preset) in BrushPreset.allCases.enumerated() {
            model.setBrush(preset); model.setWidth(20 + Double(index))
            model.setOpacity(0.4); model.setSpacing(0.35); model.setDensity(0.7)
            model.setPressure(true); model.setStabilization(0.55)
            expected[preset] = try XCTUnwrap(model.document?.brush)
        }
        model.selectTool(.eraser); model.setSoftEraser(true)
        model.setInputWidth(77); model.setInputOpacity(0.42)
        let eraser = model.eraserBrush
        let restarted = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await restarted.create()
        XCTAssertEqual(restarted.document?.brush.preset, BrushPreset.allCases.last)
        for preset in BrushPreset.allCases {
            restarted.setBrush(preset)
            XCTAssertEqual(restarted.document?.brush, expected[preset], preset.name)
        }
        restarted.selectTool(.eraser)
        XCTAssertEqual(restarted.inputBrush, eraser)
        restarted.setSoftEraser(false)
        XCTAssertEqual(restarted.eraserBrush.opacity, eraser.opacity)
    }

    func testOpeningOldProjectPreservesPersonalSettingsAndExistingInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ornamentalist-old-project-brush-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var drawing = DrawingDocument()
        let point = StrokeSample(point: Point(x: 30, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        drawing.strokes = [InkStroke(samples: [point])]
        try await repository.save(drawing, generation: 1)
        let model = StudioModel(repository: repository, preferences: preferences)
        await model.open(drawing.id)
        model.setWidth(42); model.setOpacity(0.35)
        let restarted = StudioModel(repository: repository, preferences: preferences)
        await restarted.open(drawing.id)
        XCTAssertEqual(restarted.document?.brush.width, 42)
        XCTAssertEqual(restarted.document?.brush.opacity, 0.35)
        XCTAssertEqual(restarted.document?.strokes, drawing.strokes)
    }

    func testGalleryRepairsMissingPreviewsAndUpdatesClosedDrawing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        let first = DrawingDocument(), second = DrawingDocument()
        try await repository.save(first, generation: 1)
        try await repository.save(second, generation: 1)
        let model = StudioModel(repository: repository)
        await model.refresh()
        for _ in 0..<100 {
            if model.projects.count == 2, model.projects.allSatisfy({ $0.thumbnail != nil }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.projects.count, 2)
        for project in model.projects {
            let data = try XCTUnwrap(project.thumbnail)
            XCTAssertNotNil(UIImage(data: data))
        }
        let oldPreview = try XCTUnwrap(model.projects.first(where: { $0.id == first.id })?.thumbnail)
        XCTAssertEqual(model.projects.first(where: { $0.id == first.id })?.modified, first.modified)
        await model.open(first.id)
        let input = StrokeSample(point: Point(x: 1024, y: 1024), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        model.append(InkStroke(brush: InkBrush(width: 160), samples: [input]))
        await model.close()
        for _ in 0..<100 {
            if let data = model.projects.first(where: { $0.id == first.id })?.thumbnail, data != oldPreview { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(model.projects.first(where: { $0.id == first.id })?.thumbnail, oldPreview)
        XCTAssertNil(model.error)
    }

    func testConcurrentErrorsPreserveFirstAlertAndCanBeCopiedAfterDismissal() {
        let model = StudioModel()
        model.error = "First graphics failure"
        for _ in 0..<100 { model.error = "Later save failure" }
        XCTAssertEqual(model.error, "First graphics failure")
        XCTAssertEqual(model.errorReport, "First graphics failure\n\nLater save failure")
        model.error = nil
        XCTAssertNil(model.error)
        XCTAssertTrue(model.errorReport.contains("First graphics failure"))
        model.error = "New failure"
        XCTAssertEqual(model.error, "New failure")
    }

    func testQuickBrushSettingsRememberPresetsAndFreezeDuringStroke() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Ornamentalist-brush-test-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await model.create()
        model.setInputWidth(42); model.setInputOpacity(0.35)
        let fineliner = try XCTUnwrap(model.document?.brush)
        model.setBrush(.airbrush); model.setInputWidth(95); model.setInputOpacity(0.12)
        let airbrush = try XCTUnwrap(model.document?.brush)
        model.setBrush(.fineliner); XCTAssertEqual(model.document?.brush, fineliner)
        model.selectTool(.eraser); model.setInputWidth(66); model.setInputOpacity(0.45)
        XCTAssertEqual(model.inputBrush.width, 66); XCTAssertEqual(model.document?.brush, fineliner)
        model.setDrawing(true); model.setInputWidth(20); model.setInputOpacity(1)
        XCTAssertEqual(model.inputBrush.width, 66); XCTAssertEqual(model.inputBrush.opacity, 0.45)
        model.setDrawing(false); model.selectTool(.brush); model.setBrush(.airbrush)
        XCTAssertEqual(model.document?.brush, airbrush)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let reopened = StudioModel(repository: DocumentRepository(directory: folder), preferences: preferences)
        await reopened.open(try XCTUnwrap(model.document?.id))
        XCTAssertEqual(reopened.document?.brush, airbrush)
        reopened.setBrush(.fineliner); XCTAssertEqual(reopened.document?.brush, fineliner)
    }

    func testSizePreviewUsesCanvasScaleWithoutModelRevisions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder)); await model.create()
        model.setWidth(100)
        let view = PencilCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600); view.layoutIfNeeded()
        let before = model.generation
        model.brushPreviewRequested?(true)
        let cursors = (view.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        let cursor = try XCTUnwrap(cursors.last)
        XCTAssertFalse(cursor.isHidden)
        XCTAssertEqual(try XCTUnwrap(cursor.path).boundingBoxOfPath.width, 100 * 600 / 2048 * 0.92, accuracy: 0.001)
        view.frame.size = CGSize(width: 400, height: 300); view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(cursor.path).boundingBoxOfPath.width, 100 * 300 / 2048 * 0.92, accuracy: 0.001)
        XCTAssertEqual(model.generation, before)
        model.selectTool(.eyedropper); view.synchronize(); XCTAssertTrue(cursor.isHidden)
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        XCTAssertEqual(Set(taps.map(\.numberOfTouchesRequired)), Set([2, 3]))
        XCTAssertTrue(taps.allSatisfy { $0.numberOfTapsRequired == 1 && !$0.cancelsTouchesInView })
    }
    func testDuplicateMergeUndoAndEyedropperTools() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); d.size = Point(x: 128, y: 128)
        d.symmetry = SymmetryConfiguration(repetitions: 1, center: Point(x: 64, y: 64))
        let p = StrokeSample(point: Point(x: 30, y: 25), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(brush: InkBrush(width: 20), symmetry: d.symmetry, samples: [p], color: InkColor(green: 1))]
        try await repository.save(d, generation: 1)
        let model = StudioModel(repository: repository); await model.open(d.id)
        model.selectTool(.eraser); model.setEraserWidth(45); model.setSoftEraser(true)
        XCTAssertEqual(model.eraserBrush.width, 45); XCTAssertTrue(model.eraserBrush.usesStamps)
        model.setDrawing(true); model.selectTool(.eyedropper); model.duplicateLayer(d.activeLayerID)
        XCTAssertEqual(model.tool, .eraser); XCTAssertEqual(model.document?.layers.count, 1)
        model.setDrawing(false); model.duplicateLayer(d.activeLayerID)
        let copyID = try XCTUnwrap(model.document?.activeLayerID)
        XCTAssertEqual(model.document?.layers.count, 2)
        await model.mergeLayerDown(copyID)
        XCTAssertEqual(model.document?.layers.count, 1); XCTAssertNotNil(model.document?.layers[0].raster)
        XCTAssertEqual(model.usedSamples, 0)
        model.undo(); XCTAssertEqual(model.document?.layers.count, 2); XCTAssertEqual(model.usedSamples, 2)
        model.redo(); XCTAssertEqual(model.document?.layers.count, 1)
        model.selectTool(.eyedropper); await model.pickColor(at: p.point)
        XCTAssertEqual(model.document?.color.hex, "#00FF00"); XCTAssertEqual(model.tool, .brush)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let (opened, _) = try await repository.open(d.id)
        XCTAssertNotNil(opened.layers[0].raster)
    }

    func testLayerOpacityDragIsOneUndoAndColorChangesRespectActiveStroke() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder)); await model.create()
        let id = try XCTUnwrap(model.document?.activeLayerID)
        model.beginLayerOpacityEdit()
        model.setLayerOpacity(id, value: 0.8); model.setLayerOpacity(id, value: 0.6); model.setLayerOpacity(id, value: 0.4)
        model.finishLayerOpacityEdit()
        XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        model.undo(); XCTAssertEqual(model.document?.activeLayer?.opacity, 1); XCTAssertFalse(model.canUndo)
        model.redo(); XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        let red = InkColor(red: 1)
        model.setColor(red); model.setBrush(.softShader)
        XCTAssertEqual(model.document?.color, red)
        model.setDrawing(true); model.setColor(InkColor(blue: 1)); model.setLayerOpacity(id, value: 0.9)
        XCTAssertEqual(model.document?.color, red); XCTAssertEqual(model.document?.activeLayer?.opacity, 0.4)
        model.setDrawing(false)
        for i in 0..<20 { model.setColor(InkColor(red: Double(i) / 20)) }
        XCTAssertEqual(model.document?.recentColors.count, 12)
        let saved = await model.saveNow(); XCTAssertTrue(saved)
    }

    func testBrushChangesFreezeDuringInputAndSaveWithoutChangingOldInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder), model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        model.setBrush(.dotShader); model.setOpacity(0.4); model.setSpacing(0.6); model.setDensity(0.8)
        let brush = try XCTUnwrap(model.document?.brush)
        model.setDrawing(true)
        model.setBrush(.airbrush); model.setWidth(100); model.setOpacity(1); model.setSpacing(2); model.setDensity(0.2)
        XCTAssertEqual(model.document?.brush, brush)
        model.setDrawing(false)
        let p = StrokeSample(point: Point(x: 100, y: 100), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let ink = InkStroke(brush: brush, samples: [p])
        model.append(ink); model.setBrush(.softShader)
        XCTAssertEqual(model.document?.strokes, [ink])
        let saved = await model.saveNow(); XCTAssertTrue(saved)
        let (reopened, _) = try await repository.open(id)
        XCTAssertEqual(reopened.brush.preset, .softShader); XCTAssertEqual(reopened.strokes, [ink])
        model.setBrush(.fineliner); model.setOpacity(0.2)
        XCTAssertEqual(model.document?.brush.opacity, 0.2)
        XCTAssertEqual(model.document?.strokes, [ink])
    }

    func testImmediateUndoCancelsPendingCanvasPreparationWithoutBlockingInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create(); model.addLayer()
        let layerID = try XCTUnwrap(model.document?.activeLayerID)
        let s = StrokeSample(point: Point(x: 50, y: 70), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        model.append(InkStroke(samples: [s], layerID: layerID))
        let view = PencilCanvasView(model: model)
        view.synchronize()
        model.undo()
        view.synchronize()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(model.document?.strokes.isEmpty == true)
        XCTAssertFalse(model.isPreparing)
        XCTAssertTrue(model.canDraw)
        withExtendedLifetime(view) {}
    }

    func testLayerEditsAreFrozenDuringStrokeAndLockBlocksDrawing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(repository: DocumentRepository(directory: folder))
        await model.create(); model.addLayer()
        let id = try XCTUnwrap(model.document?.activeLayerID)
        model.setDrawing(true)
        model.deleteLayer(id); model.toggleLayerVisibility(id); model.toggleLayerLock(id); model.setMirror(true)
        XCTAssertEqual(model.document?.layers.count, 2)
        XCTAssertFalse(model.document?.symmetry.mirror ?? true)
        XCTAssertTrue(model.document?.canDrawOnActiveLayer == true)
        model.setDrawing(false); model.toggleLayerLock(id)
        XCTAssertFalse(model.canDraw)
        model.undo(); XCTAssertTrue(model.canDraw)
        model.setMirror(true)
        let s = StrokeSample(point: Point(x: 100, y: 120), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let ink = InkStroke(symmetry: try XCTUnwrap(model.document?.symmetry), samples: [s], layerID: id)
        model.append(ink); model.deleteLayer(id)
        XCTAssertEqual(model.usedSamples, 0)
        model.undo()
        XCTAssertEqual(model.usedSamples, 1)
        XCTAssertEqual(model.document?.strokes, [ink])
        XCTAssertEqual(model.document?.activeLayerID, id)
        let saved = await model.saveNow()
        XCTAssertTrue(saved)
    }

    func testShowcaseUsesValidReopenableDrawings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        try await StudioShowcase.seed(repository: repository)
        let projects = try await repository.list()
        XCTAssertEqual(Set(projects.map(\.title)), Set(["Solstice", "Quiet orbit", "Petal study"]))
        for project in projects {
            XCTAssertNotNil(project.thumbnail)
            let (drawing, recovered) = try await repository.open(project.id)
            XCTAssertFalse(recovered)
            XCTAssertFalse(drawing.strokes.isEmpty)
        }
    }

    func testCloseLocksUndoRedoAndSettingsUntilExactSnapshotIsSaved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder, saveDelayNanoseconds: 100_000_000)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let sample = StrokeSample(point: Point(x: 30, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let stroke = InkStroke(samples: [sample])
        model.append(stroke)
        let generation = model.generation
        let closing = Task { await model.close() }
        for _ in 0..<100 where !model.busy { await Task.yield() }
        XCTAssertTrue(model.busy)
        model.undo(); model.redo(); model.setWidth(20); model.setRepetitions(64)
        XCTAssertEqual(model.generation, generation)
        await closing.value
        XCTAssertNil(model.document)
        let (saved, _) = try await repository.open(id)
        XCTAssertEqual(saved.strokes, [stroke])
        XCTAssertEqual(saved.brush.width, 5)
        XCTAssertEqual(saved.symmetry.repetitions, 8)
    }
    func testCanvasCheckpointContainsConfirmedActiveInk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let p = StrokeSample(point: Point(x: 15, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let active = InkStroke(samples: [p])
        model.captureActiveStroke = { active }
        model.setDrawing(true)
        await model.checkpointActiveInk()
        XCTAssertTrue(model.document?.strokes.isEmpty == true)
        let (recovered, usedJournal) = try await repository.open(id)
        XCTAssertTrue(usedJournal)
        XCTAssertEqual(recovered.strokes, [active])
        model.setDrawing(false)
    }
    func testCanceledFingerCheckpointDoesNotReappearAfterSuccessfulSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        let model = StudioModel(repository: repository)
        await model.create()
        let id = try XCTUnwrap(model.document?.id)
        let p = StrokeSample(point: Point(x: 15, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        let tentative = InkStroke(samples: [p])
        model.captureActiveStroke = { tentative }; model.setDrawing(true)
        await model.checkpointActiveInk()
        model.captureActiveStroke = { nil }
        model.discardActiveCheckpoint()
        _ = await model.saveNow()
        let (reopened, _) = try await repository.open(id)
        XCTAssertTrue(reopened.strokes.isEmpty)
    }
}
