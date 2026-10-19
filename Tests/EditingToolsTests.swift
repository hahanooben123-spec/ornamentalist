import XCTest
@testable import OrnamentalistCore

final class EditingToolsTests: XCTestCase {
    func testArchivedStructuralHistoryPreservesUndoAndRedoExactly() async throws {
        var drawing = DrawingDocument(), history = StrokeHistory()
        var snapshots = [drawing]
        for i in 0..<14 {
            let before = drawing
            drawing.layers[0].name = "Layer \(i)"
            drawing.strokes.append(ink())
            history.recordLayerChange(from: before, to: drawing)
            snapshots.append(drawing)
        }
        XCTAssertTrue(history.needsCompaction)
        history = await history.compacted()
        XCTAssertFalse(history.needsCompaction)
        for expected in snapshots.dropLast().reversed() {
            XCTAssertTrue(history.undo(in: &drawing)); XCTAssertEqual(drawing, expected)
        }
        history = await history.compacted()
        for expected in snapshots.dropFirst() {
            XCTAssertTrue(history.redo(in: &drawing)); XCTAssertEqual(drawing, expected)
        }
    }
    func testImagePlacementRoundTripSharedImageAndLegacyMigration() throws {
        var d = DrawingDocument()
        var image = raster()
        image.placement = RasterPlacement(center: Point(x: 900, y: 700), scale: 0.5, rotation: .pi / 2, flipHorizontal: true)
        d.layers[0].raster = image
        let corners = image.corners(canvas: d.size)
        XCTAssertEqual((corners[1] - corners[0]).length, 1024, accuracy: 0.000001)
        XCTAssertEqual((corners[2] - corners[1]).length, 1024, accuracy: 0.000001)
        let center = image.matrix(canvas: d.size).apply(Point(x: 1024, y: 1024))
        XCTAssertEqual(center.x, 900, accuracy: 0.000001)
        XCTAssertEqual(center.y, 700, accuracy: 0.000001)
        _ = try LayerManager.duplicate(d.activeLayerID, in: &d)
        d.layers[1].raster?.placement?.center.x += 100
        try d.validate()
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(d, decoded)
        var old = DrawingDocument(); old.version = 7; old.layers[0].raster = raster()
        try old.validate()
        XCTAssertEqual(old.layers[0].raster?.corners(canvas: old.size), [.zero, Point(x: 2048, y: 0), Point(x: 2048, y: 2048), Point(x: 0, y: 2048)])
        old.layers[0].raster?.placement = image.placement
        XCTAssertThrowsError(try old.validate())
        d.layers[0].raster?.placement?.scale = .nan
        XCTAssertThrowsError(try d.validate())
    }

    func testIncrementalStrokeBudgetMatchesFullReplayForEveryBrush() throws {
        for preset in BrushPreset.allCases {
            var brush = preset.makeBrush(); brush.width = 10; brush.pressureEnabled = true
            var session = StrokeSession(brush: brush, symmetry: SymmetryConfiguration(), existingSamples: 0,
                                        existingVertices: 0, operation: .erase)
            XCTAssertEqual(session.estimatedVertexCount, 0)
            for i in 0..<40 {
                let point = Point(x: 30 + Double(i) * 0.8, y: 35 + sin(Double(i) * 0.2) * 4)
                _ = try session.append(StrokeSample(point: point, pressure: 0.2 + Double(i % 8) * 0.1,
                                                    altitude: 1, azimuth: 0, time: Double(i)))
                XCTAssertEqual(session.estimatedVertexCount, StrokeGeometry.estimatedVertexCount(session.stroke), preset.name)
            }
        }
    }

    private func ink(layer: UUID = DrawingLayer.legacyID) -> InkStroke {
        InkStroke(brush: BrushPreset.dotShader.makeBrush(), samples: [StrokeSample(point: Point(x: 40, y: 50), pressure: 1,
                                                                                  altitude: 1, azimuth: 0, time: 1)], layerID: layer)
    }
    // Header-only fixture for Foundation validation, not an image decoder test.
    private func raster() -> LayerRaster {
        var bytes = [UInt8](repeating: 0, count: 33)
        bytes.replaceSubrange(0..<8, with: [137, 80, 78, 71, 13, 10, 26, 10])
        bytes.replaceSubrange(12..<16, with: [73, 72, 68, 82])
        bytes[18] = 8; bytes[22] = 8 // 2048 × 2048
        return LayerRaster(png: Data(bytes), width: 2048, height: 2048)
    }
    func testDuplicatePreservesScatterAndErasersWithFreshStrokeIdentities() throws {
        var d = DrawingDocument(); d.layers[0].opacity = 0.4
        var a = ink(); a.symmetry.mirror = true; var e = ink(); e.operation = .erase
        d.strokes = [a, e]
        let before = d
        XCTAssertTrue(try LayerManager.duplicate(d.activeLayerID, in: &d))
        XCTAssertEqual(d.layers.count, 2); XCTAssertEqual(d.layers[1].opacity, 0.4)
        XCTAssertEqual(d.layers[1].name, "Layer 1 copy")
        for (original, copy) in zip(before.strokes, d.strokes.suffix(2)) {
            XCTAssertNotEqual(copy.id, original.id); XCTAssertEqual(copy.seedID, original.seedID)
            XCTAssertEqual(copy.layerID, d.activeLayerID); XCTAssertEqual(copy.operation, original.operation)
            XCTAssertEqual(BrushGeometry.mesh(copy), BrushGeometry.mesh(original))
        }
        try d.validate()
    }
    func testDuplicateBudgetRejectionIsAtomic() throws {
        var d = DrawingDocument()
        for _ in 1..<LayerManager.maximumLayers { _ = LayerManager.add(in: &d) }
        let before = d
        XCTAssertThrowsError(try LayerManager.duplicate(d.activeLayerID, in: &d))
        XCTAssertEqual(d, before)
    }
    func testMergeReplacesTwoLayersAndUndoRestoresExactEditableInk() throws {
        var d = DrawingDocument(), history = StrokeHistory()
        let lower = d.activeLayerID
        d.strokes = [ink()]; _ = LayerManager.add(in: &d)
        let top = d.activeLayerID; d.strokes.append(ink(layer: top))
        d.layers[0].opacity = 0.3; d.layers[1].opacity = 0.7
        let before = d, base = raster()
        XCTAssertTrue(try LayerManager.mergeDown(top, raster: base, in: &d))
        history.recordLayerChange(from: before, to: d)
        XCTAssertEqual(d.layers.count, 1); XCTAssertEqual(d.activeLayerID, lower)
        XCTAssertEqual(d.layers[0].opacity, 1); XCTAssertEqual(d.layers[0].raster, base); XCTAssertTrue(d.strokes.isEmpty)
        XCTAssertTrue(history.undo(in: &d)); XCTAssertEqual(d, before)
        XCTAssertTrue(history.redo(in: &d)); XCTAssertEqual(d.layers[0].raster, base)
    }
    func testMergeGuardsAndRasterValidation() throws {
        var d = DrawingDocument(); let lower = d.activeLayerID
        XCTAssertFalse(LayerManager.canMergeDown(lower, in: d))
        _ = LayerManager.add(in: &d); let top = d.activeLayerID
        d.layers[0].isVisible = false; XCTAssertFalse(LayerManager.canMergeDown(top, in: d))
        d.layers[0].isVisible = true; d.layers[1].isLocked = true
        XCTAssertFalse(LayerManager.canMergeDown(top, in: d))
        var invalid = raster(); invalid.width = 1024
        XCTAssertThrowsError(try invalid.validate(canvas: d.size))
        invalid = raster(); invalid.png[0] = 0
        XCTAssertThrowsError(try invalid.validate(canvas: d.size))
        d.layers[0].raster = raster(); d.layers[1].raster = d.layers[0].raster
        d.layers[1].raster?.png[32] = 1 // Same raster identity cannot mean different bytes.
        XCTAssertThrowsError(try d.validate())
    }
    func testEraserSessionFreezeAndPersistentOperation() throws {
        var session = StrokeSession(brush: InkBrush(width: 30), symmetry: SymmetryConfiguration(mirror: true),
                                    existingSamples: 0, existingVertices: 0, operation: .erase)
        let sample = ink().samples[0]; _ = try session.append(sample)
        let decoded = try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(session.stroke))
        XCTAssertEqual(decoded.operation, .erase); XCTAssertTrue(decoded.symmetry.mirror)
        XCTAssertEqual(BrushGeometry.mesh(decoded), BrushGeometry.mesh(session.stroke))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ink())) as? [String: Any])
        json.removeValue(forKey: "operation"); json.removeValue(forKey: "geometrySeed")
        let old = try JSONDecoder().decode(InkStroke.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.operation, .ink); XCTAssertEqual(old.seedID, old.id)
    }
    func testMergedBaseAndDuplicateSeedsPersistInEditableExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); d.layers[0].raster = raster(); d.strokes = [ink()]
        _ = try LayerManager.duplicate(d.activeLayerID, in: &d)
        try await repository.save(d, generation: 1)
        let (saved, _) = try await repository.open(d.id)
        let file = try await repository.exportProject(saved)
        defer { try? FileManager.default.removeItem(at: file) }
        let imported = try await repository.importProject(at: file)
        XCTAssertEqual(imported.version, 16); XCTAssertEqual(imported.layers, d.layers)
        XCTAssertEqual(imported.strokes, d.strokes)
    }
}
