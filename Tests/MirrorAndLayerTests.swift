import XCTest
@testable import OrnamentalistCore

final class MirrorAndLayerTests: XCTestCase {
    private func stroke(layer: UUID = DrawingLayer.legacyID) -> InkStroke {
        InkStroke(samples: [StrokeSample(point: Point(x: 20, y: 30), pressure: 1, altitude: 1, azimuth: 0, time: 1)], layerID: layer)
    }

    func testMirrorReflectsAroundGuidesAtArbitraryCenter() {
        let center = Point(x: 90, y: 70)
        let symmetry = SymmetryConfiguration(repetitions: 4, center: center, mirror: true)
        let p = Point(x: 120, y: 80)
        XCTAssertEqual(symmetry.instanceCount, 8)
        XCTAssertEqual(symmetry.guideRayCount, 8)
        let positions = symmetry.matrices.map { $0.apply(p) }
        for pair in [(120.0, 80.0), (120, 60), (80, 100), (100, 100), (60, 60), (60, 80), (100, 40), (80, 40)] {
            XCTAssertTrue(positions.contains { abs($0.x - pair.0) < 1e-8 && abs($0.y - pair.1) < 1e-8 })
        }
        for m in symmetry.matrices {
            XCTAssertEqual(m.apply(center).x, center.x, accuracy: 1e-8)
            XCTAssertEqual(m.apply(center).y, center.y, accuracy: 1e-8)
            XCTAssertEqual((m.apply(p) - center).length, (p - center).length, accuracy: 1e-8)
        }
        XCTAssertEqual(SymmetryConfiguration(repetitions: 64, mirror: true).matrices.count, 128)
    }

    func testLegacyVersionTwoMigratesToOneVisibleLayerWithoutMirror() throws {
        var original = DrawingDocument(); original.strokes = [stroke()]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["version"] = 2; json.removeValue(forKey: "layers"); json.removeValue(forKey: "activeLayerID")
        var symmetry = try XCTUnwrap(json["symmetry"] as? [String: Any]); symmetry.removeValue(forKey: "mirror")
        json["symmetry"] = symmetry
        var strokes = try XCTUnwrap(json["strokes"] as? [[String: Any]])
        strokes[0].removeValue(forKey: "layerID"); strokes[0]["symmetry"] = symmetry
        json["strokes"] = strokes
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONSerialization.data(withJSONObject: json))
        try decoded.validate()
        XCTAssertEqual(decoded.layers, [DrawingLayer(id: DrawingLayer.legacyID)])
        XCTAssertEqual(decoded.strokes[0].layerID, decoded.activeLayerID)
        XCTAssertFalse(decoded.symmetry.mirror)
        XCTAssertFalse(decoded.strokes[0].symmetry.mirror)
        XCTAssertEqual(decoded.strokes[0].samples, original.strokes[0].samples)
    }

    func testLayersOrderVisibilityLockAndValidation() throws {
        var d = DrawingDocument()
        let bottom = d.activeLayerID
        XCTAssertTrue(LayerManager.add(in: &d)); let top = d.activeLayerID
        let a = stroke(layer: top), b = stroke(layer: bottom)
        d.strokes = [a, b]
        XCTAssertEqual(d.visibleStrokes.map(\.id), [b.id, a.id])
        XCTAssertTrue(LayerManager.move(top, up: false, in: &d))
        XCTAssertEqual(d.visibleStrokes.map(\.id), [a.id, b.id])
        XCTAssertTrue(LayerManager.toggleLock(top, in: &d)); XCTAssertFalse(d.canDrawOnActiveLayer)
        XCTAssertEqual(d.visibleStrokes.count, 2)
        XCTAssertTrue(LayerManager.toggleVisibility(top, in: &d))
        XCTAssertEqual(d.visibleStrokes.map(\.id), [b.id])
        try d.validate()
        d.strokes[0].layerID = UUID()
        XCTAssertThrowsError(try d.validate())
    }

    func testDeleteUndoRedoRestoresExactLayerInkAndSelection() throws {
        var d = DrawingDocument(), history = StrokeHistory()
        XCTAssertTrue(LayerManager.add(in: &d)); let top = d.activeLayerID
        d.strokes = [stroke(), stroke(layer: top)]
        let before = d
        XCTAssertTrue(LayerManager.delete(top, in: &d))
        history.recordLayerChange(from: before, to: d)
        XCTAssertEqual(d.strokes.count, 1)
        XCTAssertTrue(history.undo(in: &d))
        XCTAssertEqual(d, before)
        XCTAssertTrue(history.redo(in: &d))
        XCTAssertFalse(d.layers.contains { $0.id == top })
        XCTAssertEqual(d.strokes.count, 1)
        XCTAssertFalse(LayerManager.delete(d.activeLayerID, in: &d))
        try d.validate()
    }

    func testStrokeUndoRedoRetainsItsLayerAndMirrorAcrossLayerChanges() {
        var d = DrawingDocument(), history = StrokeHistory()
        let initial = d
        _ = LayerManager.add(in: &d)
        history.recordLayerChange(from: initial, to: d)
        var ink = stroke(layer: d.activeLayerID); ink.symmetry.mirror = true
        history.recordNewStroke(ink, in: &d)
        _ = history.undo(in: &d); _ = history.undo(in: &d)
        XCTAssertEqual(d.layers.count, 1); XCTAssertTrue(d.strokes.isEmpty)
        _ = history.redo(in: &d); _ = history.redo(in: &d)
        XCTAssertEqual(d.strokes, [ink]); XCTAssertEqual(d.activeLayerID, ink.layerID)
        _ = history.undo(in: &d)
        let before = d; _ = LayerManager.toggleVisibility(d.activeLayerID, in: &d)
        history.recordLayerChange(from: before, to: d)
        XCTAssertFalse(history.canRedo)
    }

    func testLayerLimitAndNamesCannotMakeDocumentInvalid() throws {
        var d = DrawingDocument()
        for _ in 1..<LayerManager.maximumLayers { XCTAssertTrue(LayerManager.add(in: &d)) }
        XCTAssertFalse(LayerManager.add(in: &d))
        XCTAssertTrue(LayerManager.rename(d.activeLayerID, name: String(repeating: "a", count: 200), in: &d))
        XCTAssertEqual(d.activeLayer?.name.count, 80)
        XCTAssertFalse(LayerManager.rename(d.activeLayerID, name: "  ", in: &d))
        try d.validate()
        d.layers[0].id = d.layers[1].id
        XCTAssertThrowsError(try d.validate())
    }

    func testInputFreezesLayerAndMirrorForConfirmedAndPredictedInk() throws {
        let layerID = UUID()
        var session = StrokeSession(brush: InkBrush(), symmetry: SymmetryConfiguration(mirror: true),
                                    existingSamples: 0, existingVertices: 0, layerID: layerID)
        let point = stroke().samples[0]
        _ = try session.append(point)
        var prediction = point; prediction.time = 2; prediction.point.x += 20
        _ = session.preview(predictions: [prediction])
        XCTAssertEqual(session.stroke.layerID, layerID)
        XCTAssertTrue(session.stroke.symmetry.mirror)
        XCTAssertEqual(session.stroke.samples, [point])
    }

    func testProjectRepositoryRoundTripPreservesLayersAndMirror() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); _ = LayerManager.add(in: &d)
        _ = LayerManager.rename(d.activeLayerID, name: "Details", in: &d)
        d.symmetry.mirror = true
        var ink = stroke(layer: d.activeLayerID); ink.symmetry = d.symmetry
        d.strokes = [ink]
        _ = LayerManager.toggleVisibility(d.activeLayerID, in: &d)
        try await repository.save(d, generation: 4)
        let (saved, _) = try await repository.open(d.id)
        XCTAssertEqual(saved.layers, d.layers); XCTAssertEqual(saved.strokes, d.strokes)
        XCTAssertEqual(saved.activeLayerID, d.activeLayerID); XCTAssertTrue(saved.symmetry.mirror)
        let url = try await repository.exportProject(saved)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await repository.importProject(at: url)
        XCTAssertNotEqual(imported.id, d.id)
        XCTAssertEqual(imported.layers, d.layers); XCTAssertEqual(imported.strokes, d.strokes)
    }
}
