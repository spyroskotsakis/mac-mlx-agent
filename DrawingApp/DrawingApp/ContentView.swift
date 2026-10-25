import SwiftUI

struct ContentView: View {
    @State private var lines: [Line] = []
    @State private var current: Line?

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, _ in
                for line in lines {
                    var path = Path()
                    path.addLines(line.points)
                    context.stroke(path, with: .color(line.color), lineWidth: line.width)
                }
                if let line = current {
                    var path = Path()
                    path.addLines(line.points)
                    context.stroke(path, with: .color(line.color), lineWidth: line.width)
                }
            }
            .background(Color.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = value.location
                        if current == nil {
                            current = Line(points: [p], color: .black, width: 3)
                        } else {
                            current?.points.append(p)
                        }
                    }
                    .onEnded { _ in
                        if let c = current { lines.append(c) }
                        current = nil
                    }
            )

            HStack {
                Button("Clear") { lines.removeAll() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
        }
    }
}

struct Line {
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
}
