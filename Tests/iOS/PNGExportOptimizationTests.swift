import XCTest
import UIKit
@testable import Ornamentalist

final class PNGExportOptimizationTests: XCTestCase {
    func testCanceledExportDoesNotProduceAnImage() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try PNGExporter.data(document: DrawingDocument(), transparent: true)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let canceled = await task.value
        XCTAssertTrue(canceled)
    }
    func testDirectFillPixelsMatchPNGDecodedPixels() throws {
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 2, center: Point(x: 64, y: 64), mirror: true)
        var brush = BrushPreset.softShader.makeBrush(); brush.width = 30; brush.opacity = 0.3
        document.strokes = [InkStroke(brush: brush, symmetry: document.symmetry,
            samples: [StrokeSample(point: Point(x: 80, y: 45), pressure: 0.6, altitude: 0.8, azimuth: 0, time: 0)])]
        let direct = try XCTUnwrap(PNGExporter.image(document: document, transparent: false).cgImage)
        let encoded = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: false))?.cgImage)
        XCTAssertEqual(try bytes(direct), try bytes(encoded))
    }
    func testOptimizedPainterPreservesMirroredBrushesAndErasers() throws {
        for preset in BrushPreset.allCases {
            for operation in [StrokeOperation.ink, .erase] {
                var brush = preset.makeBrush()
                brush.width = 24; brush.opacity = 0.37; brush.falloff = 0.2
                brush.tiltShading = 0.7; brush.pressureEnabled = true
                let samples = [Point(x: -15, y: 2), Point(x: 32, y: 30), Point(x: 85, y: 68)].enumerated().map {
                    StrokeSample(point: $0.element, pressure: 0.4 + Double($0.offset) * 0.25,
                                 altitude: 0.4, azimuth: 0.6, time: Double($0.offset))
                }
                let stroke = InkStroke(brush: brush,
                    symmetry: SymmetryConfiguration(repetitions: 4, center: Point(x: 32, y: 32)),
                    samples: samples, operation: operation)
                let expected = try pixels(stroke, reference: true)
                let actual = try pixels(stroke, reference: false)
                let largestDifference = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(largestDifference, 4, "\(preset), \(operation)")
            }
        }
    }
    func testRegionExportMatchesFullResolutionCrop() throws {
        var document = DrawingDocument(); document.size = Point(x: 128, y: 128)
        document.symmetry = SymmetryConfiguration(repetitions: 4, center: Point(x: 64, y: 64))
        var brush = BrushPreset.airbrush.makeBrush(); brush.width = 32
        document.strokes = [InkStroke(brush: brush, symmetry: document.symmetry,
            samples: [StrokeSample(point: Point(x: 57, y: 40), pressure: 1, altitude: 1, azimuth: 0, time: 0)])]
        let full = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: true))?.cgImage)
        let region = CGRect(x: 0, y: 0, width: 64, height: 64)
        let cropped = try XCTUnwrap(full.cropping(to: region))
        let direct = try XCTUnwrap(UIImage(data: PNGExporter.data(document: document, transparent: true, region: region))?.cgImage)
        XCTAssertEqual(direct.width, 64); XCTAssertEqual(direct.height, 64)
        XCTAssertEqual(try bytes(cropped), try bytes(direct))
    }
    private func pixels(_ stroke: InkStroke, reference: Bool) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { output in
            let context = output.cgContext
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if reference { Self.referencePaint(stroke, in: context) }
            else { PNGExporter.paint(stroke, in: context) }
        }
        return try bytes(XCTUnwrap(image.cgImage))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try output.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return output
    }
    private static func referencePaint(_ stroke: InkStroke, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if stroke.operation == .erase { context.setBlendMode(.destinationOut) }
        let ink = stroke.color
        if stroke.brush.usesStamps {
            let locations: [CGFloat] = (0...32).map { CGFloat($0) / 32 }
            let colors = locations.map { radius in
                UIColor(red: ink.red, green: ink.green, blue: ink.blue,
                        alpha: stroke.brush.dabOpacity * BrushGeometry.coverage(radius: Double(radius), softness: stroke.brush.effectiveSoftness)).cgColor
            }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
            let dabs = BrushGeometry.dabs(stroke)
            for matrix in stroke.symmetry.matrices {
                context.saveGState()
                context.concatenate(CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                                                      tx: matrix.tx, ty: matrix.ty))
                for dab in dabs where dab.radius > 0 {
                    context.saveGState()
                    if dab.opacity < 1 { context.setAlpha(CGFloat(dab.opacity)) }
                    context.translateBy(x: dab.center.x, y: dab.center.y)
                    context.rotate(by: dab.angle)
                    context.scaleBy(x: dab.radius, y: dab.radius * dab.aspect)
                    if stroke.brush.effectiveSoftness > 0 {
                        if let gradient {
                            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                                       endCenter: .zero, endRadius: 1, options: [])
                        }
                    } else {
                        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: stroke.brush.opacity).cgColor)
                        context.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
                    }
                    context.restoreGState()
                }
                context.restoreGState()
            }
            return
        }
        let isolated = stroke.brush.opacity < 1
        if isolated {
            // Apply solid-brush opacity once to the complete stroke, including
            // intersections between symmetry copies. The group's interior is
            // opaque, so its overlapping triangles cannot darken the stroke.
            context.setAlpha(CGFloat(stroke.brush.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.setFillColor(UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1).cgColor)
        let vertices = StrokeGeometry.mesh(stroke)
        // A single union fill keeps the original opaque fineliner free of seams.
        for matrix in stroke.symmetry.matrices {
            let path = CGMutablePath()
            for i in stride(from: 0, to: vertices.count, by: 3) {
                let a = matrix.apply(vertices[i]), b = matrix.apply(vertices[i+1]), c = matrix.apply(vertices[i+2])
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
                path.addLine(to: CGPoint(x: c.x, y: c.y))
                path.closeSubpath()
            }
            context.addPath(path); context.fillPath()
        }
        if isolated { context.endTransparencyLayer() }
    }

}
