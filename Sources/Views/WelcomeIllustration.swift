import SwiftUI

/// Original, resolution-independent artwork: a record becomes a neatly tagged album.
/// The illustration stays decorative; the welcome screen supplies its accessible copy.
struct WelcomeIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    private let ink = Color(red: 0.12, green: 0.14, blue: 0.29)
    private let blue = Color(red: 0.34, green: 0.33, blue: 0.88)
    private let lavender = Color(red: 0.78, green: 0.77, blue: 1)
    private let mint = Color(red: 0.62, green: 0.91, blue: 0.78)

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 360, size.height / 320)
            context.translateBy(x: (size.width - 360 * scale) / 2,
                                y: (size.height - 320 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            drawBackdrop(in: context)
            drawRecord(in: context)
            drawSleeve(in: context)
            drawTag(in: context)
            drawFormat("MP3", at: CGPoint(x: 72, y: 55), angle: -9, in: context)
            drawFormat("FLAC", at: CGPoint(x: 59, y: 263), angle: -8, in: context)
            drawFormat("M4A", at: CGPoint(x: 296, y: 65), angle: 10, in: context)

            drawSparkle(at: CGPoint(x: 43, y: 123), radius: 10, color: blue, in: context)
            drawSparkle(at: CGPoint(x: 282, y: 282), radius: 8, color: mint, in: context)
            drawSparkle(at: CGPoint(x: 194, y: 34), radius: 6,
                        color: colorScheme == .dark ? lavender : blue.opacity(0.55), in: context)
        }
        .aspectRatio(360.0 / 320.0, contentMode: .fit)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func drawBackdrop(in context: GraphicsContext) {
        let halo = Path(ellipseIn: CGRect(x: 39, y: 36, width: 282, height: 266))
        context.fill(halo, with: .color(blue.opacity(colorScheme == .dark ? 0.13 : 0.055)))

        var orbit = Path()
        orbit.move(to: CGPoint(x: 95, y: 39))
        orbit.addCurve(to: CGPoint(x: 330, y: 204),
                       control1: CGPoint(x: 257, y: -3), control2: CGPoint(x: 348, y: 68))
        context.stroke(orbit, with: .color(lavender.opacity(colorScheme == .dark ? 0.3 : 0.65)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 7]))

        var lowerOrbit = Path()
        lowerOrbit.move(to: CGPoint(x: 26, y: 204))
        lowerOrbit.addCurve(to: CGPoint(x: 198, y: 301),
                            control1: CGPoint(x: 32, y: 288), control2: CGPoint(x: 115, y: 311))
        context.stroke(lowerOrbit, with: .color(lavender.opacity(0.38)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round))

        for row in 0..<3 {
            for column in 0..<4 {
                let dot = CGRect(x: 307 + CGFloat(column) * 8,
                                 y: 229 + CGFloat(row) * 8, width: 2, height: 2)
                context.fill(Path(ellipseIn: dot), with: .color(lavender.opacity(0.6)))
            }
        }
        context.fill(Path(ellipseIn: CGRect(x: 122, y: 289, width: 5, height: 5)),
                     with: .color(mint))
        context.fill(Path(ellipseIn: CGRect(x: 315, y: 116, width: 5, height: 5)),
                     with: .color(lavender))
    }

    private func drawRecord(in context: GraphicsContext) {
        var record = context
        record.translateBy(x: 226, y: 134)
        let disk = Path(ellipseIn: CGRect(x: -87, y: -87, width: 174, height: 174))
        var shadow = record
        shadow.addFilter(.shadow(color: .black.opacity(0.16), radius: 13, x: 3, y: 9))
        shadow.fill(disk, with: .linearGradient(
            Gradient(colors: [Color(red: 0.24, green: 0.26, blue: 0.43), ink,
                              Color(red: 0.08, green: 0.1, blue: 0.2)]),
            startPoint: CGPoint(x: -70, y: -80), endPoint: CGPoint(x: 70, y: 90)))

        for radius in stride(from: CGFloat(38), through: 78, by: 6) {
            let groove = Path(ellipseIn: CGRect(x: -radius, y: -radius,
                                               width: radius * 2, height: radius * 2))
            record.stroke(groove, with: .color(lavender.opacity(0.12)), lineWidth: 0.7)
        }
        var reflection = Path()
        reflection.addArc(center: .zero, radius: 71, startAngle: .degrees(-85),
                          endAngle: .degrees(-27), clockwise: false)
        record.stroke(reflection, with: .color(.white.opacity(0.23)),
                      style: StrokeStyle(lineWidth: 2, lineCap: .round))
        record.fill(Path(ellipseIn: CGRect(x: -31, y: -31, width: 62, height: 62)),
                    with: .linearGradient(Gradient(colors: [lavender, blue]),
                                          startPoint: CGPoint(x: -28, y: -25),
                                          endPoint: CGPoint(x: 26, y: 30)))
        record.stroke(Path(ellipseIn: CGRect(x: -23, y: -23, width: 46, height: 46)),
                      with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        record.fill(Path(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10)),
                    with: .color(ink))
        record.fill(Path(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4)),
                    with: .color(lavender))
    }

    private func drawSleeve(in context: GraphicsContext) {
        var sleeve = context
        sleeve.translateBy(x: 145, y: 169)
        sleeve.rotate(by: .degrees(-11))
        let bounds = CGRect(x: -85, y: -90, width: 170, height: 180)
        let outline = Path(roundedRect: bounds, cornerRadius: 12)
        var shadow = sleeve
        shadow.addFilter(.shadow(color: ink.opacity(0.19), radius: 12, x: 0, y: 11))
        shadow.fill(outline, with: .color(Color(red: 0.88, green: 0.87, blue: 1)))

        var artwork = sleeve
        artwork.clip(to: outline)
        artwork.fill(Path(ellipseIn: CGRect(x: 20, y: -56, width: 40, height: 40)),
                     with: .color(Color(red: 1, green: 0.88, blue: 0.62)))

        // Sweeping bands echo the shape of a waveform without copying a fingerprint motif.
        let waveColors = [Color(red: 0.67, green: 0.65, blue: 0.98),
                          Color(red: 0.48, green: 0.46, blue: 0.95), blue]
        for (index, color) in waveColors.enumerated() {
            let offset = CGFloat(index) * 28
            var wave = Path()
            wave.move(to: CGPoint(x: -110, y: -8 + offset))
            wave.addCurve(to: CGPoint(x: 105, y: -30 + offset),
                          control1: CGPoint(x: -30, y: -93 + offset),
                          control2: CGPoint(x: 8, y: 67 + offset))
            wave.addLine(to: CGPoint(x: 110, y: 108))
            wave.addLine(to: CGPoint(x: -110, y: 108))
            wave.closeSubpath()
            artwork.fill(wave, with: .color(color))
        }

        let heights: [CGFloat] = [8, 16, 26, 13, 34, 44, 24, 14, 30, 20, 10]
        for (index, height) in heights.enumerated() {
            let bar = CGRect(x: -53 + CGFloat(index) * 10, y: 25 - height / 2,
                             width: 3, height: height)
            artwork.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                         with: .color(.white.opacity(index % 3 == 0 ? 0.6 : 0.95)))
        }
        artwork.fill(Path(roundedRect: CGRect(x: -64, y: -69, width: 42, height: 4), cornerRadius: 2),
                     with: .color(blue.opacity(0.72)))
        artwork.fill(Path(roundedRect: CGRect(x: -64, y: -59, width: 26, height: 3), cornerRadius: 1.5),
                     with: .color(blue.opacity(0.28)))
        artwork.fill(Path(roundedRect: CGRect(x: -63, y: 67, width: 53, height: 3), cornerRadius: 1.5),
                     with: .color(.white.opacity(0.6)))
        artwork.fill(Path(roundedRect: CGRect(x: -63, y: 75, width: 34, height: 2), cornerRadius: 1),
                     with: .color(.white.opacity(0.3)))
        sleeve.stroke(outline, with: .color(.white.opacity(0.42)), lineWidth: 1)
    }

    private func drawTag(in context: GraphicsContext) {
        var tag = context
        tag.translateBy(x: 239, y: 237)
        tag.rotate(by: .degrees(8))

        // A real tag silhouette links the artwork to MusTag's app icon.
        var outline = Path()
        outline.move(to: CGPoint(x: -64, y: -43))
        outline.addLine(to: CGPoint(x: 41, y: -43))
        outline.addQuadCurve(to: CGPoint(x: 47, y: -40), control: CGPoint(x: 45, y: -43))
        outline.addLine(to: CGPoint(x: 75, y: -7))
        outline.addQuadCurve(to: CGPoint(x: 75, y: 7), control: CGPoint(x: 81, y: 0))
        outline.addLine(to: CGPoint(x: 47, y: 40))
        outline.addQuadCurve(to: CGPoint(x: 41, y: 43), control: CGPoint(x: 45, y: 43))
        outline.addLine(to: CGPoint(x: -64, y: 43))
        outline.addQuadCurve(to: CGPoint(x: -74, y: 33), control: CGPoint(x: -74, y: 43))
        outline.addLine(to: CGPoint(x: -74, y: -33))
        outline.addQuadCurve(to: CGPoint(x: -64, y: -43), control: CGPoint(x: -74, y: -43))
        outline.closeSubpath()

        var shadow = tag
        shadow.addFilter(.shadow(color: ink.opacity(0.2), radius: 11, x: 0, y: 7))
        shadow.fill(outline, with: .color(Color(red: 0.99, green: 0.98, blue: 0.95)))
        tag.stroke(outline, with: .color(lavender.opacity(0.55)), lineWidth: 1)

        tag.fill(Path(roundedRect: CGRect(x: -57, y: -26, width: 29, height: 29), cornerRadius: 7),
                 with: .color(blue))
        var note = Path()
        note.move(to: CGPoint(x: -41, y: -5))
        note.addLine(to: CGPoint(x: -41, y: -19))
        note.addLine(to: CGPoint(x: -34, y: -21))
        tag.stroke(note, with: .color(.white), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
        tag.fill(Path(ellipseIn: CGRect(x: -47, y: -8, width: 7, height: 5)), with: .color(.white))

        for (rect, opacity) in [(CGRect(x: -18, y: -22, width: 48, height: 4), 0.8),
                                (CGRect(x: -18, y: -12, width: 33, height: 3), 0.28),
                                (CGRect(x: -57, y: 17, width: 69, height: 3), 0.25),
                                (CGRect(x: -57, y: 25, width: 45, height: 3), 0.13)] {
            tag.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink.opacity(opacity)))
        }
        tag.fill(Path(ellipseIn: CGRect(x: 52, y: -4, width: 8, height: 8)), with: .color(lavender))
        tag.stroke(Path(ellipseIn: CGRect(x: 50, y: -6, width: 12, height: 12)),
                   with: .color(blue.opacity(0.2)), lineWidth: 1)

        var string = Path()
        string.move(to: CGPoint(x: 56, y: 0))
        string.addCurve(to: CGPoint(x: 61, y: -78),
                        control1: CGPoint(x: 108, y: 4), control2: CGPoint(x: 104, y: -70))
        string.addCurve(to: CGPoint(x: 70, y: -48),
                        control1: CGPoint(x: 32, y: -81), control2: CGPoint(x: 43, y: -38))
        tag.stroke(string, with: .color(colorScheme == .dark ? lavender : blue.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        let seal = CGRect(x: 12, y: 9, width: 30, height: 30)
        tag.fill(Path(ellipseIn: seal), with: .color(mint))
        var check = Path()
        check.move(to: CGPoint(x: 21, y: 24))
        check.addLine(to: CGPoint(x: 25, y: 28))
        check.addLine(to: CGPoint(x: 33, y: 19))
        tag.stroke(check, with: .color(Color(red: 0.13, green: 0.4, blue: 0.32)),
                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
    }

    private func drawFormat(_ title: String, at point: CGPoint, angle: Double, in context: GraphicsContext) {
        var chip = context
        chip.translateBy(x: point.x, y: point.y)
        chip.rotate(by: .degrees(angle))
        let outline = Path(roundedRect: CGRect(x: -26, y: -13, width: 52, height: 26), cornerRadius: 8)
        let surface = colorScheme == .dark ? Color(red: 0.17, green: 0.18, blue: 0.28) : .white
        var shadow = chip
        shadow.addFilter(.shadow(color: ink.opacity(0.07), radius: 5, x: 0, y: 3))
        shadow.fill(outline, with: .color(surface))
        chip.stroke(outline, with: .color(lavender.opacity(colorScheme == .dark ? 0.3 : 0.6)), lineWidth: 1)
        let label = Text(title).font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1).foregroundColor(colorScheme == .dark ? lavender : blue)
        chip.draw(label, at: .zero)
    }

    private func drawSparkle(at center: CGPoint, radius: CGFloat, color: Color, in context: GraphicsContext) {
        var star = Path()
        star.move(to: CGPoint(x: center.x, y: center.y - radius))
        star.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: center)
        context.fill(star, with: .color(color))
    }
}
