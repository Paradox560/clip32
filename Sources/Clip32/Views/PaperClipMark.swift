import SwiftUI

/// A small stationery mark that stays crisp in native headers and onboarding.
/// Its colors match the bundled app icon; no capacity number is part of the mark.
struct PaperClipMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            context.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 64 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            context.fill(Path(roundedRect: CGRect(x: 1, y: 1, width: 62, height: 62), cornerRadius: 15), with: .color(Color(red: 0.17, green: 0.35, blue: 0.26)))

            var rear = context
            rear.translateBy(x: 34, y: 34)
            rear.rotate(by: .degrees(8))
            rear.translateBy(x: -34, y: -34)
            rear.fill(Path(roundedRect: CGRect(x: 19, y: 13, width: 30, height: 39), cornerRadius: 2), with: .color(Color(red: 0.76, green: 0.81, blue: 0.71)))

            var paper = Path()
            paper.move(to: CGPoint(x: 17, y: 11))
            paper.addLine(to: CGPoint(x: 40, y: 11))
            paper.addLine(to: CGPoint(x: 47, y: 18))
            paper.addLine(to: CGPoint(x: 47, y: 49))
            paper.addQuadCurve(to: CGPoint(x: 45, y: 51), control: CGPoint(x: 47, y: 51))
            paper.addLine(to: CGPoint(x: 17, y: 51))
            paper.addQuadCurve(to: CGPoint(x: 15, y: 49), control: CGPoint(x: 15, y: 51))
            paper.addLine(to: CGPoint(x: 15, y: 13))
            paper.addQuadCurve(to: CGPoint(x: 17, y: 11), control: CGPoint(x: 15, y: 11))
            paper.closeSubpath()
            context.fill(paper, with: .color(Color(red: 0.97, green: 0.955, blue: 0.90)))

            var fold = Path()
            fold.move(to: CGPoint(x: 40, y: 11))
            fold.addLine(to: CGPoint(x: 40, y: 18))
            fold.addLine(to: CGPoint(x: 47, y: 18))
            fold.closeSubpath()
            context.fill(fold, with: .color(Color(red: 0.83, green: 0.84, blue: 0.76)))

            for (y, width) in [(35.0, 18.0), (39.0, 18.0), (43.0, 12.0)] {
                context.fill(Path(roundedRect: CGRect(x: 21, y: y, width: width, height: 1), cornerRadius: 0.5), with: .color(Color(red: 0.58, green: 0.66, blue: 0.55).opacity(0.45)))
            }

            var clip = Path()
            clip.move(to: CGPoint(x: 28, y: 16))
            clip.addLine(to: CGPoint(x: 28, y: 25))
            clip.addCurve(to: CGPoint(x: 25, y: 25), control1: CGPoint(x: 28, y: 27), control2: CGPoint(x: 25, y: 27))
            clip.addLine(to: CGPoint(x: 25, y: 13))
            clip.addCurve(to: CGPoint(x: 30.5, y: 13), control1: CGPoint(x: 25, y: 9), control2: CGPoint(x: 30.5, y: 9))
            clip.addLine(to: CGPoint(x: 30.5, y: 26))
            clip.addCurve(to: CGPoint(x: 22.5, y: 26), control1: CGPoint(x: 30.5, y: 32), control2: CGPoint(x: 22.5, y: 32))
            clip.addLine(to: CGPoint(x: 22.5, y: 15))
            context.stroke(clip, with: .color(Color(red: 0.20, green: 0.40, blue: 0.29)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
