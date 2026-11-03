import ImageIO
import SwiftUI

/// Decode only the pixels needed for this view, including for embedded artwork.
struct ArtworkImage: View {
    let artwork: AudioArtwork?
    var maximumPixelSize = 600
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.indigo.opacity(0.06))
        .task(id: Request(data: artwork?.data, maximumPixelSize: maximumPixelSize)) {
            thumbnail = nil
            guard let data = artwork?.data else { return }
            let size = maximumPixelSize
            let result = await Task.detached(priority: .utility) {
                Self.makeThumbnail(data: data, maximumPixelSize: size)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
        .accessibilityHidden(true)
    }

    private struct Request: Equatable {
        let data: Data?
        let maximumPixelSize: Int
    }

    nonisolated private static func makeThumbnail(data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary)
    }
}

struct ArtworkPreviewButton: View {
    let artwork: AudioArtwork?
    var size: CGFloat = 160
    var label = L10n.text("Preview cover", "预览封面")
    @Environment(\.displayScale) private var displayScale
    @State private var showsPreview = false

    var body: some View {
        Button { showsPreview = true } label: {
            ArtworkImage(artwork: artwork, maximumPixelSize: Int(size * displayScale))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
        .buttonStyle(.plain)
        .disabled(artwork == nil)
        .accessibilityLabel(artwork == nil ? L10n.text("No cover", "无封面") : label)
        .sheet(isPresented: $showsPreview) {
            if let artwork { ArtworkPreviewSheet(artwork: artwork) }
        }
    }
}

private struct ArtworkPreviewSheet: View {
    let artwork: AudioArtwork
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArtworkImage(artwork: artwork, maximumPixelSize: 1600)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .navigationTitle(L10n.text("Cover preview", "封面预览"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("Done", "完成")) { dismiss() }
                            .accessibilityIdentifier("artworkPreviewDoneButton")
                    }
                }
        }
    }
}
