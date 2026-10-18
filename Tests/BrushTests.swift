import XCTest
@testable import OrnamentalistCore

final class BrushTests: XCTestCase {
    private func sample(_ x: Double, y: Double = 40, time: Double = 1) -> StrokeSample {
        StrokeSample(point: Point(x: x, y: y), pressure: 0.7, altitude: 1, azimuth: 0, time: time)
    }
    func testEveryPresetValidatesAndHasFiniteDistinctGeometry() throws {
        XCTAssertEqual(BrushPreset.allCases.count, 14)
        for preset in BrushPreset.allCases {
            var d = DrawingDocument(); d.brush = preset.makeBrush()
            d.strokes = [InkStroke(brush: d.brush, samples: [sample(40), sample(100, time: 2)])]
            try d.validate()
            let mesh = BrushGeometry.mesh(d.strokes[0])
            XCTAssertFalse(mesh.isEmpty, preset.name)
            XCTAssertTrue(mesh.allSatisfy { $0.point.isFinite && $0.local.isFinite })
            XCTAssertLessThanOrEqual(mesh.count, StrokeGeometry.estimatedVertexCount(d.strokes[0]))
        }
    }
    func testAllBrushesLivePredictedAndReopenedMeshesMatch() throws {
        for preset in BrushPreset.allCases {
            var b = preset.makeBrush(); b.stabilization = 0.4
            var session = StrokeSession(brush: b, symmetry: SymmetryConfiguration(mirror: true), existingSamples: 0, existingVertices: 0)
            var live: [BrushVertex] = []
            for i in 0..<8 {
                live += try session.append(sample(20 + Double(i) * 12, y: 40 + Double(i % 3), time: Double(i)))
                let before = session.stroke
                _ = session.preview(predictions: [sample(160, y: 80, time: Double(i) + 0.5)])
                XCTAssertEqual(session.stroke, before)
            }
            live += BrushGeometry.tail(session.stroke)
            let reopened = try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(session.stroke))
            XCTAssertEqual(live, BrushGeometry.mesh(reopened), preset.name)
        }
    }
    func testDotSpacingDependsOnDistanceNotEventFrequency() {
        let b = BrushPreset.dots.makeBrush(), id = UUID()
        let sparse = InkStroke(id: id, brush: b, samples: [sample(0), sample(120, time: 2)])
        let dense = InkStroke(id: id, brush: b, samples: (0...120).map { sample(Double($0), time: Double($0) + 1) })
        let a = BrushGeometry.dabs(sparse), c = BrushGeometry.dabs(dense)
        XCTAssertEqual(a.count, 11); XCTAssertEqual(a.count, c.count)
        for (x, y) in zip(a, c) { XCTAssertEqual(x.center.x, y.center.x, accuracy: 1e-8) }
        XCTAssertGreaterThan((a[1].center - a[0].center).length, a[0].radius * 2)
    }
    func testStippleDensityAndSeedAreStable() {
        var b = BrushPreset.dotShader.makeBrush()
        let id = UUID(), samples = [sample(50)]
        b.density = 0.1
        let light = InkStroke(id: id, brush: b, samples: samples)
        b.density = 1
        let dense = InkStroke(id: id, brush: b, samples: samples)
        XCTAssertEqual(BrushGeometry.dabs(light).count, 2)
        XCTAssertEqual(BrushGeometry.dabs(dense).count, 20)
        XCTAssertEqual(BrushGeometry.mesh(dense), BrushGeometry.mesh(dense))
        var other = dense; other.id = UUID()
        XCTAssertNotEqual(BrushGeometry.mesh(dense), BrushGeometry.mesh(other))
    }
    func testLegacyBrushDecodingPreservesOriginalInk() throws {
        let data = Data(#"{"width":5,"pressureEnabled":false,"stabilization":0.25,"geometryVersion":2}"#.utf8)
        let b = try JSONDecoder().decode(InkBrush.self, from: data)
        XCTAssertEqual(b, InkBrush())
        let ink = InkStroke(brush: b, samples: [sample(30), sample(50, time: 2)])
        XCTAssertEqual(BrushGeometry.mesh(ink).map(\.point), StrokeGeometry.mesh(ink))
    }
    func testSoftCoverageIsSmoothAndFallsToZero() {
        XCTAssertEqual(BrushGeometry.coverage(radius: 0, softness: 1), 1)
        XCTAssertEqual(BrushGeometry.coverage(radius: 0.5, softness: 1), 0.5)
        XCTAssertEqual(BrushGeometry.coverage(radius: 1, softness: 1), 0)
        XCTAssertEqual(BrushGeometry.coverage(radius: 1.1, softness: 1), 0)
    }
    func testBrushValidationAndInputBudgetRejectOversizedJump() throws {
        var b = BrushPreset.stippleDense.makeBrush(); b.width = 1; b.spacing = 0.06
        var session = StrokeSession(brush: b, symmetry: SymmetryConfiguration(), existingSamples: 0,
                                    existingVertices: DrawingLimits.vertexCount - 500)
        _ = try session.append(sample(0))
        XCTAssertThrowsError(try session.append(sample(100_000, time: 2)))
        XCTAssertEqual(session.stroke.samples.count, 1)
        var d = DrawingDocument(); d.strokes = [session.stroke]; try d.validate()
        d.brush.opacity = .nan; XCTAssertThrowsError(try d.validate())
        d.brush = b; d.brush.density = 2; XCTAssertThrowsError(try d.validate())
        d.brush = b; d.brush.spacing = 0; XCTAssertThrowsError(try d.validate())
        d.brush = InkBrush(); d.brush.opacity = 0.5; XCTAssertNoThrow(try d.validate())
        d.version = 6; XCTAssertThrowsError(try d.validate())
    }

    func testTranslucentSolidBrushesRoundTripWithoutChangingGeometry() throws {
        for preset in [BrushPreset.fineliner, .brushPen] {
            var d = DrawingDocument(); d.brush = preset.makeBrush(); d.brush.opacity = 0.35
            d.strokes = [InkStroke(brush: d.brush, samples: [sample(30), sample(70, time: 2)])]
            try d.validate()
            let restored = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(d))
            try restored.validate(); XCTAssertEqual(restored.brush.opacity, 0.35)
            var opaque = d.strokes[0]; opaque.brush.opacity = 1
            XCTAssertEqual(BrushGeometry.mesh(opaque), BrushGeometry.mesh(restored.strokes[0]))
        }
    }
    func testBrushesAndHiddenLayerSurviveRepositoryAndEditableExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); _ = LayerManager.add(in: &d)
        d.brush = BrushPreset.dotShader.makeBrush(); d.brush.density = 0.8; d.brush.opacity = 0.3
        d.symmetry.mirror = true
        d.strokes = [InkStroke(brush: d.brush, symmetry: d.symmetry, samples: [sample(50)], layerID: d.activeLayerID)]
        d.layers[1].isVisible = false
        try await repository.save(d, generation: 1)
        let (saved, _) = try await repository.open(d.id)
        XCTAssertEqual(saved.brush, d.brush); XCTAssertEqual(saved.strokes, d.strokes)
        let url = try await repository.exportProject(saved)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await repository.importProject(at: url)
        XCTAssertEqual(imported.version, 7); XCTAssertEqual(imported.layers, d.layers)
        XCTAssertEqual(BrushGeometry.mesh(imported.strokes[0]), BrushGeometry.mesh(d.strokes[0]))
    }
}
