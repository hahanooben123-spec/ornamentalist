import XCTest
@testable import OrnamentalistCore

final class CoreTests: XCTestCase {
    func testTileMirrorAndRotationsCullInvisibleCopiesAndKeepLegacyInk() throws {
        var symmetry = SymmetryConfiguration(repetitions: 8, center: Point(x: 1024, y: 1024), mirror: false,
            tileCount: 4, tileSymmetry: true, tileRepetitions: 1)
        let source = CGRect(x: 96, y: 116, width: 8, height: 8)
        XCTAssertEqual(symmetry.matrices(for: source).count, 16)
        symmetry.mirror = true
        XCTAssertEqual(symmetry.matrices(for: source).count, 32)
        symmetry.tileRepetitions = 2
        XCTAssertEqual(symmetry.matrices(for: source).count, 64)
        let point = Point(x: 100, y: 120)
        let visible = symmetry.matrices(for: source).map { $0.apply(point) }
        for expected in [Point(x: 100, y: 120), Point(x: 100, y: 392), Point(x: 412, y: 392)] {
            XCTAssertTrue(visible.contains { ($0 - expected).length < 0.000001 })
        }
        var document = DrawingDocument(); document.symmetry = symmetry
        try document.validate()
        let restored = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.symmetry, symmetry)
        document.version = 18; XCTAssertThrowsError(try document.validate())
        document.version = 19; document.symmetry.tileRepetitions = 9; XCTAssertThrowsError(try document.validate())
        let old = try JSONDecoder().decode(SymmetryConfiguration.self, from: Data(#"{"repetitions":8,"center":{"x":1024,"y":1024},"mirror":true,"tileCount":4}"#.utf8))
        XCTAssertFalse(old.tileSymmetry); XCTAssertEqual(old.instanceCount, 121)
        XCTAssertEqual(old.matrices.count, 121)
        // Extreme off-paper input cannot allocate an unbounded transform array.
        XCTAssertLessThan(symmetry.matrices(for: CGRect(x: -100000, y: -100000, width: 200000, height: 200000)).count, 2000)
    }
    func testTileSymmetryRepeatsAcrossCanvasAndRoundTrips() throws {
        var d = DrawingDocument(); d.symmetry.tileCount = 4; d.symmetry.tileCanvas = d.size
        try d.validate()
        XCTAssertEqual(d.symmetry.instanceCount, d.symmetry.matrices.count)
        XCTAssertEqual(d.symmetry.instanceCount, 121)
        let point = Point(x: 100, y: 120)
        let visible = d.symmetry.matrices.map { $0.apply(point) }.filter {
            (0..<d.size.x).contains($0.x) && (0..<d.size.y).contains($0.y)
        }
        XCTAssertEqual(visible.count, 16)
        XCTAssertTrue(visible.contains(Point(x: 1636, y: 1656)))
        let copy = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(copy.symmetry, d.symmetry)
        d.symmetry.tileCount = 1000
        XCTAssertThrowsError(try d.validate())
        let legacy = try JSONDecoder().decode(SymmetryConfiguration.self,
            from: Data("{\"repetitions\":8,\"center\":{\"x\":1024,\"y\":1024}}".utf8))
        XCTAssertEqual(legacy.tileCount, 0); XCTAssertEqual(legacy.matrices.count, 8)
    }
    func testShapeCorrectionRecognizesLineAndCircleAndParallelCopyKeepsSymmetry() throws {
        var stroke = InkStroke()
        stroke.samples = (0...20).map { i in
            StrokeSample(point: Point(x: Double(i) * 5, y: i % 2 == 0 ? 0 : 1), pressure: 1, altitude: 1, azimuth: 0, time: Double(i))
        }
        let line = try XCTUnwrap(StrokeGeometry.correctedShape(stroke))
        XCTAssertTrue(line.samples.allSatisfy { $0.point.y == 0 })
        let parallel = try XCTUnwrap(StrokeGeometry.parallelCopy(line, distance: 12))
        XCTAssertTrue(parallel.samples.allSatisfy { abs($0.point.y - 12) < 0.001 })
        XCTAssertNotEqual(parallel.id, line.id)
        XCTAssertEqual(parallel.symmetry, line.symmetry)
        stroke.samples = (0...64).map { i in
            let angle = Double(i) * 2 * Double.pi / 64
            return StrokeSample(point: Point(x: 100 + cos(angle) * 50, y: 100 + sin(angle) * 50), pressure: 1, altitude: 1, azimuth: 0, time: Double(i))
        }
        let circle = try XCTUnwrap(StrokeGeometry.correctedShape(stroke))
        XCTAssertEqual(circle.samples.count, 129)
        for sample in circle.samples { XCTAssertEqual((sample.point - Point(x: 100, y: 100)).length, 50, accuracy: 0.001) }
        XCTAssertLessThan((circle.samples.first!.point - circle.samples.last!.point).length, 0.001)
    }
    func testFillStopsAtOutlineAndSupportsSymmetrySeeds() {
        var rgba = [UInt8](repeating: 255, count: 5 * 3 * 4)
        for y in 0..<3 {
            let i = (y * 5 + 2) * 4
            rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
        }
        let left = FillRegion.mask(rgba: rgba, width: 5, height: 3, seeds: [(0, 1)])
        XCTAssertEqual(left.filter { $0 != 0 }.count, 6)
        XCTAssertEqual(left[4], 0)
        let both = FillRegion.mask(rgba: rgba, width: 5, height: 3, seeds: [(0, 1), (4, 1), (-1, 0)])
        XCTAssertEqual(both.filter { $0 != 0 }.count, 12)
        XCTAssertEqual(both[2], 0)
    }
    func testFillUsesFourConnectedRegionsAndRejectsInvalidBuffers() {
        let rgba: [UInt8] = [255,255,255,255, 0,0,0,255, 0,0,0,255, 255,255,255,255]
        XCTAssertEqual(FillRegion.mask(rgba: rgba, width: 2, height: 2, seeds: [(0,0)]), [255,0,0,0])
        XCTAssertTrue(FillRegion.mask(rgba: [], width: 2, height: 2, seeds: [(0,0)]).isEmpty)
    }
    func testViewportSnapshotCornersTrackZoomRotationAndPan() {
        let size = Point(x: 800, y: 600), canvas = Point(x: 2048, y: 2048)
        var source = Viewport(); source.zoom = 1.3; source.rotation = 0.4; source.pan = Point(x: 17, y: -23)
        let corners = source.documentCorners(viewSize: size, canvasSize: canvas)
        let screen = [Point.zero, Point(x: 800, y: 0), size, Point(x: 0, y: 600)]
        for (point, expected) in zip(corners, screen) {
            let actual = source.matrix(viewSize: size, canvasSize: canvas).apply(point)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001)
        }
        var destination = source; destination.zoom = 3; destination.rotation = -0.2; destination.pan = Point(x: -10, y: 30)
        let delta = source.matrix(viewSize: size, canvasSize: canvas).inverse
            .followed(by: destination.matrix(viewSize: size, canvasSize: canvas))
        for (point, original) in zip(corners, screen) {
            let direct = destination.matrix(viewSize: size, canvasSize: canvas).apply(point)
            let preview = delta.apply(original)
            XCTAssertEqual(direct.x, preview.x, accuracy: 0.000001)
            XCTAssertEqual(direct.y, preview.y, accuracy: 0.000001)
        }
    }
    func testCanvasInvalidationTracksPixelsRatherThanBrushAndSaveMetadata() {
        var drawing = DrawingDocument()
        let initial = CanvasDisplayState(drawing, guides: true)
        drawing.brush.width = 70; drawing.color = InkColor(red: 1)
        drawing.title = "Renamed"; drawing.storageRevision += 1; drawing.modified = Date()
        drawing.layers[0].name = "Renamed layer"; drawing.layers[0].isLocked = true
        XCTAssertEqual(initial, CanvasDisplayState(drawing, guides: true))
        drawing.layers[0].opacity = 0.4
        XCTAssertNotEqual(initial, CanvasDisplayState(drawing, guides: true))
        drawing.layers[0].opacity = 1
        XCTAssertNotEqual(initial, CanvasDisplayState(drawing, guides: false))
        let hiddenGuides = CanvasDisplayState(drawing, guides: false)
        drawing.symmetry.repetitions = 16
        XCTAssertEqual(hiddenGuides, CanvasDisplayState(drawing, guides: false))
        XCTAssertNotEqual(initial, CanvasDisplayState(drawing, guides: true))
        drawing.strokes.append(InkStroke(samples: [sample(10, 20)]))
        XCTAssertNotEqual(hiddenGuides, CanvasDisplayState(drawing, guides: false))
    }

    func testSaveDeadlineUsesIdleOrMaximumDirtyTimeAndClearsAfterSave() {
        var schedule = SaveSchedule()
        XCTAssertNil(schedule.deadline)
        schedule.edited(at: 10); XCTAssertEqual(schedule.deadline, 10.5)
        schedule.edited(at: 10.4); XCTAssertEqual(schedule.deadline, 10.9)
        schedule.edited(at: 11.8); XCTAssertEqual(schedule.deadline, 12)
        XCTAssertFalse(schedule.isDue(at: 11.99)); XCTAssertTrue(schedule.isDue(at: 12))
        schedule.saved(); XCTAssertNil(schedule.deadline)
    }
    private func sample(_ x: Double, _ y: Double, time: Double = 1) -> StrokeSample {
        StrokeSample(point: Point(x: x, y: y), pressure: 0.6, altitude: 1, azimuth: 0, time: time)
    }
    func testEightWayRotationAroundNonOriginCenter() {
        let s = SymmetryConfiguration(repetitions: 8, center: Point(x: 300, y: 600))
        let original = Point(x: 345, y: 620)
        XCTAssertEqual(s.matrices.count, 8)
        for (index, m) in s.matrices.enumerated() {
            let p = m.apply(original)
            XCTAssertEqual((p-s.center).length, (original-s.center).length, accuracy: 1e-8)
            XCTAssertEqual(m.apply(s.center).x, s.center.x, accuracy: 1e-8)
            XCTAssertEqual(m.apply(s.center).y, s.center.y, accuracy: 1e-8)
            if index == 4 {
                XCTAssertEqual(p.x, 255, accuracy: 1e-8)
                XCTAssertEqual(p.y, 580, accuracy: 1e-8)
            }
        }
    }
    func testNoSymmetryAndSixtyFourCopies() {
        let p = Point(x: 700, y: 900)
        XCTAssertEqual(SymmetryConfiguration(repetitions: 1).matrices[0].apply(p), p)
        let matrices = SymmetryConfiguration(repetitions: 64).matrices
        XCTAssertEqual(matrices.count, 64)
        let positions = matrices.map { $0.apply(p) }
        for i in 0..<64 {
            for j in (i+1)..<64 { XCTAssertGreaterThan((positions[i]-positions[j]).length, 0.001) }
        }
    }
    func testViewportRoundTripAndSymmetryAtEveryZoom() {
        let canvas = Point(x: 2048, y: 2048), view = Point(x: 1194, y: 730)
        let p = Point(x: 1700.123, y: 800.456)
        for zoom in [0.25, 1, 4, 12] as [Double] {
            let v = Viewport(zoom: zoom, rotation: 1.234, pan: Point(x: -207, y: 319))
            let m = v.matrix(viewSize: view, canvasSize: canvas)
            let recovered = m.inverse.apply(m.apply(p))
            XCTAssertEqual(recovered.x, p.x, accuracy: 1e-8)
            XCTAssertEqual(recovered.y, p.y, accuracy: 1e-8)
            for symmetry in SymmetryConfiguration().matrices {
                let expected = m.apply(symmetry.apply(p))
                let actual = m.apply(symmetry.apply(recovered))
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-7)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-7)
            }
        }
    }
    func testLiveMeshMatchesReopenedMesh() {
        let samples = [sample(10, 10), sample(20, 40, time: 2), sample(70, 50, time: 3), sample(90, 0, time: 4)]
        let stroke = InkStroke(samples: samples)
        var live: [Point] = [], prefix: [StrokeSample] = []
        for s in samples {
            prefix.append(s)
            live += StrokeGeometry.stableAddition(samples: prefix, brush: stroke.brush)
        }
        live += StrokeGeometry.tail(samples: prefix, brush: stroke.brush)
        XCTAssertEqual(live, StrokeGeometry.mesh(stroke))
        XCTAssertEqual(live.count % 3, 0)
        XCTAssertTrue(live.allSatisfy(\.isFinite))
        XCTAssertFalse(live.isEmpty)
    }
    func testSingleTapHasGeometryAndPressureChangesWidth() {
        XCTAssertEqual(StrokeGeometry.mesh(InkStroke(samples: [sample(0, 0)])).count, InkBrush().diskSides * 3)
        let brush = InkBrush(width: 10, pressureEnabled: true)
        XCTAssertEqual(brush.radius(pressure: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(brush.radius(pressure: 1), 5, accuracy: 1e-9)
        XCTAssertLessThan(brush.radius(pressure: 0.2), brush.radius(pressure: 0.8))
    }
    func testHistoryGroupsSymmetryAndInvalidatesRedoBranch() {
        var document = DrawingDocument(), history = StrokeHistory()
        let a = InkStroke(samples: [sample(1, 1)]), b = InkStroke(samples: [sample(2, 2)])
        history.recordNewStroke(a, in: &document)
        history.recordNewStroke(b, in: &document)
        XCTAssertTrue(history.undo(in: &document))
        XCTAssertEqual(document.strokes, [a])
        XCTAssertTrue(history.redo(in: &document))
        XCTAssertEqual(document.strokes, [a, b])
        history.undo(in: &document)
        document.symmetry.repetitions = 64
        let c = InkStroke(symmetry: document.symmetry, samples: [sample(3, 3)])
        history.recordNewStroke(c, in: &document)
        XCTAssertFalse(history.redo(in: &document))
        XCTAssertEqual(document.strokes[0].symmetry.repetitions, 8)
        XCTAssertEqual(document.strokes[1].symmetry.repetitions, 64)
    }
    func testDocumentRoundTripAndValidation() throws {
        var document = DrawingDocument()
        document.strokes = [InkStroke(samples: [sample(15, 20)])]
        try document.validate()
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(document, decoded)
        document.symmetry.repetitions = 65
        XCTAssertThrowsError(try document.validate())
        document.symmetry.repetitions = 8
        document.strokes[0].samples[0].point.x = .nan
        XCTAssertThrowsError(try document.validate())
    }
    func testContinuousDottingCannotPostponeSaveDeadline() {
        var schedule = SaveSchedule()
        for i in 0..<10 { schedule.edited(at: Double(i) * 0.2) }
        XCTAssertFalse(schedule.isDue(at: 1.9))
        XCTAssertTrue(schedule.isDue(at: 2.0))
        schedule.saved()
        XCTAssertFalse(schedule.isDue(at: 10))
        schedule.edited(at: 11)
        XCTAssertFalse(schedule.isDue(at: 11.4))
        XCTAssertTrue(schedule.isDue(at: 11.5))
    }
    func testFinelinerConstantWidthAndAdaptiveRoundTips() {
        let brush = InkBrush(width: 40)
        XCTAssertEqual(brush.radius(pressure: 0), brush.radius(pressure: 1))
        XCTAssertGreaterThan(brush.diskSides, 12)
        let sagitta = 20 * (1 - cos(.pi / Double(brush.diskSides)))
        XCTAssertLessThanOrEqual(sagitta, 0.031)
    }
    func testVersionOneDocumentsPreserveOriginalBrushGeometry() throws {
        let original = DrawingDocument()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["version"] = 1; json.removeValue(forKey: "storageRevision")
        json["brush"] = ["width": 5]
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.storageRevision, 0)
        XCTAssertTrue(decoded.brush.pressureEnabled)
        XCTAssertEqual(decoded.brush.stabilization, 0)
        XCTAssertEqual(decoded.brush.diskSides, 12)
    }
    func testInputReplayRejectsDuplicateSamplesAndDoesNotPersistPredictions() throws {
        var session = StrokeSession(brush: InkBrush(stabilization: 0), symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: 0)
        let first = sample(20, 20, time: 1), second = sample(25, 35, time: 2)
        XCTAssertFalse(try session.append(first).isEmpty)
        XCTAssertTrue(try session.append(first).isEmpty)
        _ = try session.append(second)
        let confirmed = session.stroke
        XCTAssertFalse(session.preview(predictions: [sample(100, 80, time: 3)]).isEmpty)
        XCTAssertEqual(session.stroke, confirmed)
        XCTAssertEqual(session.stroke.samples, [first, second])
    }
    func testStabilizerReducesJitterWithoutChangingTimestamps() throws {
        var session = StrokeSession(brush: InkBrush(stabilization: 0.75), symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: 0)
        for i in 0..<100 {
            _ = try session.append(sample(Double(i), i % 2 == 0 ? 3 : -3, time: Double(i)/240))
        }
        let mean = session.stroke.samples.dropFirst(10).reduce(0) { $0 + abs($1.point.y) } / 90
        XCTAssertLessThan(mean, 1)
        XCTAssertEqual(session.stroke.samples.last?.time, 99.0/240)
    }
    func testExistingDocumentGeometryDoesNotConsumeNewStrokeWorkingBudget() throws {
        var session = StrokeSession(brush: InkBrush(stabilization: 0), symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: DrawingLimits.vertexCount - 2000)
        for i in 0..<1000 {
            _ = try session.append(sample(Double(i) * 3, Double(i % 2) * 4, time: Double(i)))
        }
        XCTAssertEqual(session.stroke.samples.count, 1000)
        XCTAssertGreaterThan(StrokeGeometry.estimatedVertexCount(session.stroke), 2000)
        var d = DrawingDocument(); d.strokes = [session.stroke]
        try d.validate()
    }

    func testStationaryPencilDoesNotExhaustInputOrGeometryBudget() throws {
        var session = StrokeSession(brush: InkBrush(stabilization: 0), symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: 0)
        var live: [BrushVertex] = []
        for i in 0...DrawingLimits.strokeSamples {
            live += try session.append(sample(20, 20, time: Double(i)))
        }
        XCTAssertEqual(session.stroke.samples.count, 2)
        // Out-of-order callbacks remain ignored after skipping idle samples.
        XCTAssertTrue(try session.append(sample(90, 90, time: 10)).isEmpty)
        live += try session.append(sample(50, 40, time: Double(DrawingLimits.strokeSamples + 1)))
        live += BrushGeometry.tail(session.stroke)
        XCTAssertEqual(live, BrushGeometry.mesh(session.stroke))
        XCTAssertEqual(session.estimatedVertexCount, StrokeGeometry.estimatedVertexCount(session.stroke))
        var d = DrawingDocument(); d.strokes = [session.stroke]
        try d.validate()
    }

    func testStationaryPressureChangesArePreserved() throws {
        var session = StrokeSession(brush: InkBrush(pressureEnabled: true, stabilization: 0),
                                    symmetry: SymmetryConfiguration(), existingSamples: 0, existingVertices: 0)
        for i in 0..<4 {
            var input = sample(20, 20, time: Double(i))
            input.pressure = Double(i + 1) / 4
            _ = try session.append(input)
        }
        XCTAssertEqual(session.stroke.samples.count, 4)
    }

    func testRibbonReducesLongStrokeGeometryAndPreservesReplay() throws {
        let brush = InkBrush(stabilization: 0)
        var session = StrokeSession(brush: brush, symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: 0)
        var live: [BrushVertex] = []
        for i in 0..<1000 {
            let input = sample(Double(i), 40 + sin(Double(i) * 0.02) * 15, time: Double(i))
            live += try session.append(input)
            XCTAssertEqual(session.estimatedVertexCount, StrokeGeometry.estimatedVertexCount(session.stroke))
        }
        live += BrushGeometry.tail(session.stroke)
        let reopened = try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(session.stroke))
        XCTAssertEqual(live, BrushGeometry.mesh(reopened))
        XCTAssertEqual(live.count, session.estimatedVertexCount)
        // The previous implementation emitted at least one full disk per
        // sample, even on a straight line. Require a substantial real reduction.
        let oldMinimum = session.stroke.samples.count * brush.diskSides * 3
        XCTAssertLessThan(live.count * 5, oldMinimum)
        var d = DrawingDocument(); d.strokes = [reopened]
        try d.validate()
    }

    func testRibbonMidpointEdgesMeetAndHairpinsStayFinite() {
        let brush = InkBrush(width: 18, pressureEnabled: true, stabilization: 0)
        let points = [sample(10, 10), sample(35, 30, time: 2), sample(70, 40, time: 3), sample(90, 60, time: 4)]
        let before = StrokeGeometry.stableAddition(samples: Array(points.prefix(3)), brush: brush)
        let after = StrokeGeometry.stableAddition(samples: Array(points.suffix(3)), brush: brush)
        XCTAssertEqual(before[before.count - 4], after[0])
        XCTAssertEqual(before[before.count - 1], after[1])
        for coordinates in [[0.0, 100, 0], [0, 0, 0], [0, 100, 100]] {
            let samples = coordinates.enumerated().map { sample($0.element, 20, time: Double($0.offset)) }
            let stroke = InkStroke(brush: brush, samples: samples)
            let mesh = StrokeGeometry.mesh(stroke)
            XCTAssertFalse(mesh.isEmpty)
            XCTAssertTrue(mesh.allSatisfy(\.isFinite))
            XCTAssertLessThanOrEqual(mesh.count, StrokeGeometry.estimatedVertexCount(stroke))
        }
    }

    func testTwentySixDetailedStrokesFitWithinBoundedMemoryBudget() throws {
        var d = DrawingDocument()
        for stroke in 0..<26 {
            let samples = (0..<1000).map { i in
                sample(100 + Double(i), 100 + Double(stroke) * 20 + sin(Double(i) * 0.02) * 15, time: Double(i))
            }
            d.strokes.append(InkStroke(samples: samples))
        }
        let vertices = d.strokes.reduce(0) { $0 + StrokeGeometry.estimatedVertexCount($1) }
        XCTAssertLessThan(vertices, DrawingLimits.vertexCount / 5)
        XCTAssertEqual(DrawingLimits.vertexCount, 4_000_000)
        try d.validate()
    }

    func testComplexMirroredDrawingPassesOldInputLimitAndReopens() throws {
        var document = DrawingDocument()
        let symmetry = SymmetryConfiguration(repetitions: 16, center: Point(x: 1024, y: 1024), mirror: true)
        for row in 0..<4 {
            let samples: [StrokeSample] = (0..<30_000).map { i in
                let x = 100.0 + Double(i) * 0.03
                let y = 100.0 + Double(row) * 30.0 + sin(Double(i) * 0.02) * 10.0
                return sample(x, y, time: Double(i) / 240.0)
            }
            document.strokes.append(InkStroke(symmetry: symmetry, samples: samples))
        }
        XCTAssertGreaterThan(document.strokes.reduce(0) { $0 + $1.samples.count }, 100_000)
        try document.validate()
        let data = try JSONEncoder().encode(document)
        let reopened = try JSONDecoder().decode(DrawingDocument.self, from: data)
        try reopened.validate()
        XCTAssertEqual(reopened.strokes.map(\.samples.count), [30_000, 30_000, 30_000, 30_000])
        XCTAssertTrue(reopened.strokes.allSatisfy { $0.symmetry.mirror })
    }

    func testPerStrokeLimitDoesNotTellUserToAbandonCanvas() throws {
        var session = StrokeSession(brush: InkBrush(stabilization: 0), symmetry: SymmetryConfiguration(),
                                    existingSamples: 0, existingVertices: 0)
        var stopped = false
        for i in 0..<DrawingLimits.strokeSamples {
            do { _ = try session.append(sample(Double(i % 2) * 500, 20, time: Double(i))) }
            catch DocumentError.strokeLimit { stopped = true; break }
        }
        XCTAssertTrue(stopped)
        var d = DrawingDocument(); d.strokes = [session.stroke]
        try d.validate()
    }
}
