import SwiftUI
import TurboTapeKit

extension CurveChannel {
    var color: Color {
        switch self {
        case .luma: .white
        case .red: Color(red: 0.95, green: 0.3, blue: 0.3)
        case .green: Color(red: 0.3, green: 0.85, blue: 0.4)
        case .blue: Color(red: 0.35, green: 0.55, blue: 1)
        }
    }
}

/// Colour curves for all clips at once, or for one clip on top of that.
struct ColorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Color", systemImage: "camera.filters").font(.headline)
                Spacer()
                Button("Reset") { model.resetGrade() }
                    .controlSize(.small)
                    .disabled(model.editedGrade.isIdentity)
                    .help(model.gradeScope == .all ? "Remove the curves from all clips" : "Remove this clip's own curves")
            }
            Picker("Apply to", selection: Binding(get: { model.gradeScope }, set: { model.gradeScope = $0 })) {
                ForEach(AppModel.GradeScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.timeline == nil {
                Text("Generate a video to grade its clips.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                if model.gradeScope == .single { clipChooser }
                CurveEditor()
                    .aspectRatio(1, contentMode: .fit)
                channelRow
                ForEach(CurveChannel.allCases) { strengthRow($0) }
                Text(model.gradeScope == .all
                     ? "Click the curve to add a point · drag to move · double-click a point to remove it, or empty space to reset"
                     : "This clip's curves apply on top of the curves for all clips.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private var clipChooser: some View {
        let urls = Array(Set(model.timeline?.segments.map(\.clip) ?? [])).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Picker("Clip", selection: Binding(get: { model.gradeTarget }, set: { model.gradeClip = $0 })) {
            ForEach(urls, id: \.self) { u in
                Text((model.clipGrades[u] != nil ? "● " : "") + u.deletingPathExtension().lastPathComponent).tag(Optional(u))
            }
        }
        .help("The clip to adjust (selecting a shot in the timeline picks its clip). ● = has its own curves")
    }

    private var channelRow: some View {
        HStack(spacing: 6) {
            Text("Edit").foregroundStyle(.secondary)
            Button {
                model.linkRGB.toggle()
            } label: {
                Image(systemName: model.linkRGB ? "link" : "link.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(model.linkRGB ? "R, G and B are edited together" : "Link R, G and B")
            ForEach(CurveChannel.allCases) { c in
                Button {
                    model.gradeChannel = c
                } label: {
                    Text(c.title).font(.callout.bold())
                        .frame(width: 28, height: 22)
                        .foregroundStyle(c == .luma ? Color.black : Color.white)
                        .background(RoundedRectangle(cornerRadius: 4).fill(c.color.opacity(model.gradeChannel == c ? 1 : 0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: model.gradeChannel == c ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { model.resetChannel(model.gradeChannel) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Reset the \(model.gradeChannel.title) curve")
        }
    }

    private func strengthRow(_ c: CurveChannel) -> some View {
        let value = Binding<Double>(
            get: { Double(model.editedGrade.intensity[c.rawValue]) * 100 },
            set: { model.setIntensity(Float($0 / 100), channel: c, final: false) })
        return HStack(spacing: 8) {
            Circle().fill(c.color).frame(width: 8, height: 8)
            Slider(value: value, in: 0...100) { editing in
                if editing { model.beginCurveDrag() } else { model.endCurveDrag() }
            }
            .controlSize(.small)
            Text("\(Int(value.wrappedValue.rounded()))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
        .help("Strength of the \(c.title) curve")
    }
}

/// The curve of the selected channel over the clips' histogram. Drag points, click to add one,
/// double-click a point to remove it, double-click empty space to reset the curve.
struct CurveEditor: View {
    @Environment(AppModel.self) private var model
    /// Index of the point being dragged; -1 while a click was consumed (remove / reset).
    @State private var dragIndex: Int?
    @State private var lastClick: (time: Date, at: CGPoint)?
    /// The point the last click on empty space added (the first click of a double-click adds one).
    @State private var addedPoint: CurvePoint?

    private var points: [CurvePoint] { model.editedGrade[model.gradeChannel] }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in draw(&ctx, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in changed(g, size) }
                    .onEnded { _ in ended() })
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func toScreen(_ p: CurvePoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * s.width, y: (1 - CGFloat(p.y)) * s.height)
    }

    private func fromScreen(_ q: CGPoint, _ s: CGSize) -> CurvePoint {
        CurvePoint(Float(min(max(q.x / s.width, 0), 1)), Float(min(max(1 - q.y / s.height, 0), 1)))
    }

    private func hit(_ q: CGPoint, _ s: CGSize) -> Int? {
        let d = points.enumerated().map { ($0.offset, hypot(toScreen($0.element, s).x - q.x, toScreen($0.element, s).y - q.y)) }
        return d.filter { $0.1 < 9 }.min { $0.1 < $1.1 }?.0
    }

    private func changed(_ g: DragGesture.Value, _ s: CGSize) {
        if dragIndex == nil {
            let now = Date()
            let double = lastClick.map { now.timeIntervalSince($0.time) < 0.35 && hypot($0.at.x - g.startLocation.x, $0.at.y - g.startLocation.y) < 6 } ?? false
            lastClick = (now, g.startLocation)
            let added = addedPoint
            addedPoint = nil
            // a double-click on empty space: its first click added the point the second one hits
            if let i = hit(g.startLocation, s), !(double && points[i] == added) {
                if double {
                    // remove a point (not the end points)
                    if i > 0, i < points.count - 1 {
                        var p = points
                        p.remove(at: i)
                        model.setCurve(p, final: true)
                    }
                    dragIndex = -1
                    return
                }
                dragIndex = i
                model.beginCurveDrag()
            } else if double {
                model.setCurve(ColorGrade.identityCurve, final: true)
                dragIndex = -1
                return
            } else {
                // a click on empty space adds a point there and drags it
                let q = fromScreen(g.startLocation, s)
                var p = points
                p.append(q)
                p.sort { $0.x < $1.x }
                model.beginCurveDrag()
                dragIndex = p.firstIndex(of: q)
                addedPoint = q
                model.setCurve(p, final: false)
            }
        }
        guard let i = dragIndex, i >= 0, points.indices.contains(i) else { return }
        var p = points
        var q = fromScreen(g.location, s)
        // end points stay at the edges; inner points stay between their neighbours
        if i == 0 { q.x = 0 } else if i == p.count - 1 { q.x = 1 } else { q.x = min(max(q.x, p[i - 1].x + 0.01), p[i + 1].x - 0.01) }
        p[i] = q
        model.setCurve(p, final: false)
    }

    private func ended() {
        if let i = dragIndex, i >= 0 { model.endCurveDrag() }
        dragIndex = nil
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(Color(white: 0.09)))
        var grid = Path()
        for k in 1..<4 {
            let f = CGFloat(k) / 4
            grid.move(to: CGPoint(x: f * s.width, y: 0)); grid.addLine(to: CGPoint(x: f * s.width, y: s.height))
            grid.move(to: CGPoint(x: 0, y: f * s.height)); grid.addLine(to: CGPoint(x: s.width, y: f * s.height))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

        // histogram: luma filled, colours as lines
        if let h = model.histogram {
            let n = Histogram.bins
            func path(_ v: [Float], closed: Bool) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: s.height))
                for (i, y) in v.enumerated() {
                    p.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) / CGFloat(n) * s.width, y: s.height * (1 - 0.85 * CGFloat(y))))
                }
                p.addLine(to: CGPoint(x: s.width, y: s.height))
                if closed { p.closeSubpath() }
                return p
            }
            ctx.fill(path(h.values[0], closed: true), with: .color(.white.opacity(0.16)))
            for c in [CurveChannel.red, .green, .blue] {
                ctx.stroke(path(h.values[c.rawValue], closed: false), with: .color(c.color.opacity(0.45)), lineWidth: 1)
            }
        }

        // diagonal reference
        var diag = Path()
        diag.move(to: CGPoint(x: 0, y: s.height)); diag.addLine(to: CGPoint(x: s.width, y: 0))
        ctx.stroke(diag, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        func curve(_ pts: [CurvePoint]) -> Path {
            let lut = Curves.monotoneLUT(pts, 160)
            var p = Path()
            for (i, y) in lut.enumerated() {
                let q = CGPoint(x: CGFloat(i) / 159 * s.width, y: (1 - CGFloat(min(max(y, 0), 1))) * s.height)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            return p
        }
        // the other channels' curves, faint, when they are not straight
        let g = model.editedGrade
        for c in CurveChannel.allCases where c != model.gradeChannel && !g.isIdentity(c) {
            ctx.stroke(curve(g[c]), with: .color(c.color.opacity(0.35)), lineWidth: 1)
        }
        let col = model.gradeChannel.color
        ctx.stroke(curve(points), with: .color(col), lineWidth: 1.8)
        for (i, p) in points.enumerated() {
            let q = toScreen(p, s)
            let r: CGFloat = dragIndex == i ? 6 : 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(col))
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }
}
