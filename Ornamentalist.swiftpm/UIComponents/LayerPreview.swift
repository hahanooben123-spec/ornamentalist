import SwiftUI

private struct LayerPreviewKey: Hashable {
    let layerID: UUID
    let rasterID: UUID?
    let strokes: [UUID]
}

@MainActor
struct LayerPreview: View {
    let model: StudioModel
    let document: DrawingDocument
    let layer: DrawingLayer
    let strokeIDs: [UUID]
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            TransparencyGrid()
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }.frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.25)))
            .accessibilityHidden(true)
            .task(id: LayerPreviewKey(layerID: layer.id, rasterID: layer.raster?.id,
                                      strokes: strokeIDs)) {
                image = nil
                do {
                    let data = try await model.layerThumbnail(document, id: layer.id)
                    try Task.checkCancellation()
                    image = UIImage(data: data)
                } catch { /* A preview is replaceable; the drawing remains intact. */ }
            }
    }
}

struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for y in stride(from: 0, to: Int(size.height), by: 6) {
                for x in stride(from: 0, to: Int(size.width), by: 6) where (x / 6 + y / 6) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(x), y: CGFloat(y), width: 6, height: 6)), with: .color(.gray.opacity(0.2)))
                }
            }
        }
    }
}
