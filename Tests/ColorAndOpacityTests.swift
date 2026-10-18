import XCTest
@testable import OrnamentalistCore

final class ColorAndOpacityTests: XCTestCase {
    func testHexValidationAndHSBRoundTrips() throws {
        for hex in ["#000000", "#FFFFFF", "#327DD1", "#D64545", "#85939A"] {
            let color = try XCTUnwrap(InkColor(hex: hex)); XCTAssertEqual(color.hex, hex)
            let hsb = color.hsb, other = InkColor(hue: color.hsb.hue, saturation: color.hsb.saturation, brightness: color.hsb.brightness)
            XCTAssertTrue(hsb.hue >= 0 && hsb.hue <= 1)
            XCTAssertEqual(color.red, other.red, accuracy: 1e-9)
            XCTAssertEqual(color.green, other.green, accuracy: 1e-9)
            XCTAssertEqual(color.blue, other.blue, accuracy: 1e-9)
        }
        for invalid in ["", "#ABC", "#GG0000", "1234567", "##123456"] { XCTAssertNil(InkColor(hex: invalid)) }
        XCTAssertFalse(InkColor(red: .nan).isValid)
    }
    func testVersionFourMigrationDefaultsToBlackAndFullLayerOpacity() throws {
        var d = DrawingDocument()
        d.strokes = [InkStroke(samples: [StrokeSample(point: Point(x: 30, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 1)])]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        json["version"] = 4; json.removeValue(forKey: "color"); json.removeValue(forKey: "recentColors")
        var strokes = try XCTUnwrap(json["strokes"] as? [[String: Any]])
        strokes[0].removeValue(forKey: "color"); json["strokes"] = strokes
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        layers[0].removeValue(forKey: "opacity"); json["layers"] = layers
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONSerialization.data(withJSONObject: json))
        try decoded.validate()
        XCTAssertEqual(decoded.color, .black); XCTAssertEqual(decoded.strokes[0].color, .black)
        XCTAssertEqual(decoded.layers[0].opacity, 1); XCTAssertTrue(decoded.recentColors.isEmpty)
        XCTAssertEqual(BrushGeometry.mesh(decoded.strokes[0]), BrushGeometry.mesh(d.strokes[0]))
    }
    func testLayerOpacityHistoryDoesNotChangeVisibilityOrStrokeColor() throws {
        var d = DrawingDocument(), history = StrokeHistory()
        let id = d.activeLayerID, before = d
        XCTAssertTrue(LayerManager.setOpacity(id, value: 0.3, in: &d))
        history.recordLayerChange(from: before, to: d)
        XCTAssertTrue(d.layers[0].isVisible); XCTAssertTrue(d.canDrawOnActiveLayer)
        XCTAssertTrue(history.undo(in: &d)); XCTAssertEqual(d.layers[0].opacity, 1)
        XCTAssertTrue(history.redo(in: &d)); XCTAssertEqual(d.layers[0].opacity, 0.3)
        _ = LayerManager.toggleVisibility(id, in: &d)
        XCTAssertEqual(d.layers[0].opacity, 0.3); XCTAssertFalse(d.canDrawOnActiveLayer)
        _ = LayerManager.toggleVisibility(id, in: &d)
        XCTAssertEqual(d.layers[0].opacity, 0.3)
        XCTAssertFalse(LayerManager.setOpacity(id, value: .nan, in: &d))
        _ = LayerManager.setOpacity(id, value: 2, in: &d); XCTAssertEqual(d.layers[0].opacity, 1)
        d.layers[0].opacity = -0.1; XCTAssertThrowsError(try d.validate())
    }
    func testInputCapturesColorAlongsideBrushLayerAndMirror() throws {
        let color = InkColor(red: 0.2, green: 0.7, blue: 0.4), layer = UUID()
        var session = StrokeSession(brush: BrushPreset.dotShader.makeBrush(), symmetry: SymmetryConfiguration(mirror: true),
                                    existingSamples: 0, existingVertices: 0, layerID: layer, color: color)
        let p = StrokeSample(point: Point(x: 20, y: 30), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        _ = try session.append(p)
        XCTAssertEqual(session.stroke.color, color); XCTAssertEqual(session.stroke.layerID, layer)
        XCTAssertTrue(session.stroke.symmetry.mirror)
        let decoded = try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(session.stroke))
        XCTAssertEqual(decoded, session.stroke)
    }
    func testColorOpacityAndRecentColorsPersistThroughEditableProject() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DocumentRepository(directory: folder)
        var d = DrawingDocument(); d.color = InkColor(red: 1); d.recentColors = [.black, d.color]
        d.layers[0].opacity = 0.4; d.layers[0].isVisible = false
        let p = StrokeSample(point: Point(x: 20, y: 30), pressure: 1, altitude: 1, azimuth: 0, time: 1)
        d.strokes = [InkStroke(samples: [p], color: d.color)]
        try await repository.save(d, generation: 1)
        let (saved, _) = try await repository.open(d.id)
        let url = try await repository.exportProject(saved)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await repository.importProject(at: url)
        XCTAssertEqual(imported.version, 12); XCTAssertEqual(imported.color, d.color)
        XCTAssertEqual(imported.recentColors, d.recentColors); XCTAssertEqual(imported.layers, d.layers)
        XCTAssertEqual(imported.strokes, d.strokes)
    }
}
