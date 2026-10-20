// The canvas: before and after (side by side or after only), zoom and pan, the crop box, heal spots, masks, and the histogram.
import AppKit
import SwiftUI

/// Before and after, zoomed and panned together. Pinch or ⌘= / ⌘− to zoom, hold Space and drag to pan.
/// In crop mode it shows the whole straightened frame with the crop box over it; the Heal and Masks tabs draw on the after pane.
struct CompareView: View {
    let preview: Preview
    let single: Bool  // after only, full width
    @Binding var params: Params  // the whole-photo edit: crop, heal spots and masks are drawn and edited here
    @Environment(\.displayScale) private var displayScale
    @State private var holding = false
    @State private var zoom: CGFloat = 1  // 1 = fit
    @State private var offset = CGSize.zero  // pan from centred, in points
    @State private var panStart: CGSize?
    @State private var pinchStart: (zoom: CGFloat, offset: CGSize)?
    @State private var space = false
    @State private var monitor: Any?
    @State private var paneSize = CGSize(width: 1, height: 1)

    private var onePane: Bool { single || preview.cropMode }
    /// Image size at zoom 1 inside one pane.
    private var fit: CGSize {
        guard let img = preview.after ?? preview.before else { return paneSize }
        let k = min(paneSize.width / CGFloat(img.width), paneSize.height / CGFloat(img.height))
        return CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
    }
    private var oneToOne: CGFloat { preview.original.width / max(fit.width * displayScale, 1) }  // 1 photo px = 1 screen px

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                if !onePane { panel("Before", preview.before) }
                panel(title, holding ? preview.before : preview.after, tools: true)
                    .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: {
                        holding = $0 && !space && [.edit, .chat].contains(preview.tool)  // the other tabs draw on the photo
                    })
            }
            .highPriorityGesture(pan, including: space && !preview.cropMode ? .all : .subviews)
            .simultaneousGesture(pinch, including: preview.cropMode ? .subviews : .all)
            .onChange(of: geo.size, initial: true) { resize(geo.size) }
            .onChange(of: onePane) { resize(geo.size) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .bottom) { if !preview.cropMode { zoomBar } }
        .overlay(alignment: .topTrailing) { if preview.busy { ProgressView().controlSize(.small).padding(10) } }
        .overlay { if let e = preview.error { Text(e).foregroundStyle(.white).padding().background(.red.opacity(0.8), in: .rect(cornerRadius: 8)) } }
        .onChange(of: zoom * fit.width * displayScale > preview.previewWidth * 1.1, initial: true) { _, v in preview.wantDetail = v }
        .onChange(of: preview.cropMode) { setZoom(1) }
        .onChange(of: space) { _, down in down ? NSCursor.openHand.push() : NSCursor.pop() }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
                guard e.keyCode == 49 else { return e }  // space
                if e.type == .keyUp { guard space else { return e }; space = false; return nil }
                if NSApp.keyWindow?.firstResponder is NSText { return e }  // typing in the chat box
                if !e.isARepeat { space = true }
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; if space { NSCursor.pop() } }
    }

    private func resize(_ s: CGSize) {
        paneSize = CGSize(width: max(1, onePane ? s.width : (s.width - 12) / 2), height: max(1, s.height))
    }

    private var title: String {
        switch preview.tool {
        case .crop: return "Crop"
        case .heal: return "Heal  ·  click a blemish, drag over a longer one"
        case .masks: return "Masks"
        default: return holding ? "Without edits" : onePane ? "Hold to compare" : "After  ·  hold to compare"
        }
    }

    private func panel(_ title: String, _ img: CGImage?, tools: Bool = false) -> some View {
        ZStack {
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width * zoom, height: fit.height * zoom)
                    .overlay { if tools { toolOverlay } }
                    .offset(offset)
            }
        }
        .frame(width: paneSize.width, height: paneSize.height)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            Text(title).font(.caption).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(8)
        }
    }

    @ViewBuilder private var toolOverlay: some View {
        let map = PhotoMap(geo: Geo(params, Int(preview.original.width), Int(preview.original.height)),
                           size: CGSize(width: fit.width * zoom, height: fit.height * zoom))
        switch preview.tool {
        case .crop where preview.cropMode:
            CropOverlay(crop: $params.crop, size: fit, aspect: preview.cropAspect, frameAspect: fit.width / max(fit.height, 1))
        case .heal: HealOverlay(spots: $params.heal, map: map, preview: preview)
        case .masks: MaskOverlay(masks: $params.masks, map: map, preview: preview)
        default: EmptyView()
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-").help("Zoom out (⌘−)")
            Text("\(Int((zoom / oneToOne * 100).rounded()))%").monospacedDigit().frame(minWidth: 46)
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=").help("Zoom in (⌘=)")
            Divider().frame(height: 14)
            Button("Fit") { setZoom(1) }.keyboardShortcut("0").help("Fit to screen (⌘0)")
            Button("100%") { setZoom(oneToOne) }.keyboardShortcut("1").help("Actual pixels (⌘1)")
        }
        .buttonStyle(.borderless).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.65), in: Capsule())
        .help("Pinch to zoom, hold Space and drag to pan")
        .padding(.bottom, 24)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let s = panStart ?? offset
                if panStart == nil { panStart = s; NSCursor.closedHand.push() }
                offset = clamped(CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height), zoom)
            }
            .onEnded { _ in panStart = nil; NSCursor.pop() }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let s = pinchStart ?? (zoom, offset)
                if pinchStart == nil { pinchStart = s }
                // zoom around the point under the fingers, measured from the centre of whichever pane it is in
                let right = !onePane && v.startLocation.x > paneSize.width + 6
                let p = CGPoint(x: v.startLocation.x - paneSize.width / 2 - (right ? paneSize.width + 12 : 0), y: v.startLocation.y - paneSize.height / 2)
                setZoom(s.zoom * v.magnification, about: p, from: s)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Keeps the image point under `p` (relative to the pane centre) fixed while zooming.
    private func setZoom(_ z: CGFloat, about p: CGPoint = .zero, from s: (zoom: CGFloat, offset: CGSize)? = nil) {
        let (z0, o0) = s ?? (zoom, offset), z1 = min(max(z, 1), max(4, oneToOne * 8))
        offset = clamped(CGSize(width: p.x - (p.x - o0.width) * z1 / z0, height: p.y - (p.y - o0.height) * z1 / z0), z1)
        zoom = z1
    }

    /// No panning past the image edges.
    private func clamped(_ o: CGSize, _ z: CGFloat) -> CGSize {
        let mx = max(0, (fit.width * z - paneSize.width) / 2), my = max(0, (fit.height * z - paneSize.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}

/// The crop box over the whole straightened frame: drag inside to move it, drag a corner to resize it.
/// `aspect` (width / height in pixels) locks the shape; nil is free.
struct CropOverlay: View {
    @Binding var crop: [Double]?
    let size: CGSize
    let aspect: Double?
    let frameAspect: Double
    @State private var start: [Double]?
    @State private var corner: Int?  // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right; nil moves the box

    var body: some View {
        let c = crop ?? [0, 0, 1, 1]
        let r = CGRect(x: c[0] * size.width, y: c[1] * size.height, width: c[2] * size.width, height: c[3] * size.height)
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(r) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Path { p in  // rule of thirds
                for k in 1...2 {
                    let fx = r.minX + r.width * CGFloat(k) / 3, fy = r.minY + r.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: fx, y: r.minY)); p.addLine(to: CGPoint(x: fx, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: fy)); p.addLine(to: CGPoint(x: r.maxX, y: fy))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
            Path { p in p.addRect(r) }.stroke(Color.white, lineWidth: 1.5)
            ForEach(0..<4, id: \.self) { k in
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 13, height: 13).position(corners[k])
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                if start == nil {
                    start = c
                    let near = corners.indices.min { hypot(corners[$0].x - v.startLocation.x, corners[$0].y - v.startLocation.y)
                        < hypot(corners[$1].x - v.startLocation.x, corners[$1].y - v.startLocation.y) }!
                    corner = hypot(corners[near].x - v.startLocation.x, corners[near].y - v.startLocation.y) < 24 || !r.contains(v.startLocation) ? near : nil
                }
                crop = dragged(start!, Double(v.translation.width / size.width), Double(v.translation.height / size.height))
            }
            .onEnded { _ in start = nil; corner = nil })
        .help("Drag inside to move the crop, drag a corner to resize it")
    }

    private func dragged(_ s: [Double], _ dx: Double, _ dy: Double) -> [Double] {
        guard let k = corner else { return [(s[0] + dx).clamped(0, 1 - s[2]), (s[1] + dy).clamped(0, 1 - s[3]), s[2], s[3]] }
        let left = k == 0 || k == 2, top = k == 0 || k == 1
        let fx = left ? s[0] + s[2] : s[0], fy = top ? s[1] + s[3] : s[1]  // the corner that stays put
        let mx = ((left ? s[0] : s[0] + s[2]) + dx).clamped(0, 1), my = ((top ? s[1] : s[1] + s[3]) + dy).clamped(0, 1)
        var w = max(0.05, left ? fx - mx : mx - fx), h = max(0.05, top ? fy - my : my - fy)
        if let aspect {  // keep the shape: width decides, then fit inside the frame
            let an = aspect / frameAspect, maxW = left ? fx : 1 - fx, maxH = top ? fy : 1 - fy
            h = w / an
            if h > maxH { h = maxH; w = h * an }
            if w > maxW { w = maxW; h = w / an }
        }
        return [left ? fx - w : fx, top ? fy - h : fy, w, h]
    }
}

/// Points on the shown picture (after crop and rotation, in points) <-> positions on the photo (fractions of its width
/// and height), which is where heal spots and masks live.
struct PhotoMap {
    let geo: Geo, size: CGSize
    var side: Double { Double(min(geo.sw, geo.sh)) }

    func view(_ x: Double, _ y: Double) -> CGPoint {
        let (u, v) = geo.output(Float(x) * geo.sw, Float(y) * geo.sh)
        return CGPoint(x: CGFloat(u) / CGFloat(geo.ow) * size.width, y: CGFloat(v) / CGFloat(geo.oh) * size.height)
    }

    /// The photo position `(dx, dy)` fractions of its shorter side away from (x, y).
    func view(_ x: Double, _ y: Double, plus dx: Double, _ dy: Double) -> CGPoint {
        view(x + dx * side / Double(geo.sw), y + dy * side / Double(geo.sh))
    }

    func photo(_ p: CGPoint) -> (x: Double, y: Double) {
        let (x, y) = geo.source(Float(p.x / size.width) * Float(geo.ow), Float(p.y / size.height) * Float(geo.oh))
        return (Double(x / geo.sw), Double(y / geo.sh))
    }

    /// The photo move from view point a to b, in fractions of its width and height.
    func delta(_ a: CGPoint, _ b: CGPoint) -> (x: Double, y: Double) { let p = photo(a), q = photo(b); return (q.x - p.x, q.y - p.y) }

    /// A size in fractions of the photo's shorter side, in points.
    func length(_ r: Double) -> CGFloat { CGFloat(r * side) * CGFloat(geo.k) * size.width / CGFloat(geo.ow) }

    /// How far b is from a on the photo, in fractions of its shorter side, along the photo's own axes.
    func units(_ a: (x: Double, y: Double), _ b: CGPoint) -> (x: Double, y: Double) {
        let q = photo(b); return ((q.x - a.x) * Double(geo.sw) / side, (q.y - a.y) * Double(geo.sh) / side)
    }
}

/// A circle outline that reads on light and dark photos.
private func ring(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, width: CGFloat = 1.5, dash: [CGFloat] = [], alpha: Double = 1) {
    let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.stroke(path, with: .color(.black.opacity(0.45 * alpha)), style: StrokeStyle(lineWidth: width + 1.5, dash: dash))
    ctx.stroke(path, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: width, dash: dash))
}

private func handle(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat = 5) {
    let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.fill(path, with: .color(.white))
    ctx.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 1)
}

private func line(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat = 1.5, dash: [CGFloat] = []) {
    var p = Path(); p.move(to: a); p.addLine(to: b)
    ctx.stroke(p, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: width + 1.5, dash: dash))
    ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: width, dash: dash))
}

/// Heal tab: every spot as a circle; the selected one also shows its source (dashed) with an arrow to the spot.
/// Click a blemish, or drag over a longer one, to heal it; drag a circle to move it, or its source to copy from elsewhere.
struct HealOverlay: View {
    @Binding var spots: [[Double]]?
    let map: PhotoMap
    let preview: Preview
    @State private var run: [CGPoint] = []  // the stroke being brushed, in view points
    @State private var grab: (index: Int, source: Bool, start: [Double])?
    @State private var hover: CGPoint?

    var body: some View {
        let list = (spots ?? []).filter { $0.count == 5 }, brush = map.length(preview.brushSize)
        Canvas { ctx, _ in
            for (i, s) in list.enumerated() {
                let c = map.view(s[0], s[1]), r = map.length(s[2]), selected = i == preview.selectedSpot
                ring(&ctx, c, r, width: selected ? 2 : 1, alpha: selected ? 1 : 0.7)
                if selected {
                    let sc = map.view(s[3], s[4]), d = hypot(c.x - sc.x, c.y - sc.y)
                    ring(&ctx, sc, r, dash: [4, 3])
                    if d > 2 * r {  // arrow from the source to the spot
                        let u = CGPoint(x: (c.x - sc.x) / d, y: (c.y - sc.y) / d), tip = CGPoint(x: c.x - u.x * r, y: c.y - u.y * r)
                        line(&ctx, CGPoint(x: sc.x + u.x * r, y: sc.y + u.y * r), tip, width: 1)
                        for a in [2.6, -2.6] {
                            let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                            line(&ctx, tip, CGPoint(x: tip.x + 8 * (u.x * ca - u.y * sa), y: tip.y + 8 * (u.x * sa + u.y * ca)), width: 1)
                        }
                    }
                }
            }
            for p in run { ctx.fill(Path(ellipseIn: CGRect(x: p.x - brush, y: p.y - brush, width: 2 * brush, height: 2 * brush)), with: .color(.white.opacity(0.3))) }
            if let hover, run.isEmpty, grab == nil { ring(&ctx, hover, brush, width: 1, dash: [3, 3], alpha: 0.8) }
        }
        .contentShape(Rectangle())
        .onContinuousHover { if case .active(let p) = $0 { hover = p } else { hover = nil } }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if grab == nil && run.isEmpty { begin(at: v.startLocation, list) }
                if let g = grab {
                    let d = map.delta(v.startLocation, v.location), o = g.source ? 3 : 0
                    var s = g.start
                    s[o] += d.x; s[o + 1] += d.y
                    if list.indices.contains(g.index), list[g.index] != s { var l = list; l[g.index] = s; spots = l }
                } else if let last = run.last, hypot(v.location.x - last.x, v.location.y - last.y) >= max(2, brush / 2) {
                    run.append(v.location)
                }
            }
            .onEnded { _ in
                if grab == nil { finishRun(list) }
                grab = nil
            })
        .help("Click a blemish to heal it, drag over a longer one. Drag a circle to move it, or its dashed source to copy from elsewhere.")
    }

    /// The selected spot's source, then any spot (topmost first), else a new stroke.
    private func begin(at p: CGPoint, _ list: [[Double]]) {
        func near(_ x: Double, _ y: Double, _ r: Double) -> Bool { let c = map.view(x, y); return hypot(c.x - p.x, c.y - p.y) <= max(map.length(r), 8) }
        if let i = preview.selectedSpot, list.indices.contains(i), near(list[i][3], list[i][4], list[i][2]) { grab = (i, true, list[i]); return }
        if let i = list.indices.last(where: { near(list[$0][0], list[$0][1], list[$0][2]) }) {
            preview.selectedSpot = i; grab = (i, false, list[i]); return
        }
        run = [p]
    }

    /// A click is one spot; a stroke is a run of overlapping spots that share one automatically picked source.
    private func finishRun(_ list: [[Double]]) {
        let new = run.map { p -> [Double] in let q = map.photo(p); return [q.x, q.y, preview.brushSize] }
        run = []
        guard !new.isEmpty else { return }
        let (dx, dy) = preview.photoRGB.map { healOffset($0, new) } ?? (2.5 * preview.brushSize * map.side / Double(map.geo.sw), 0)
        spots = list + new.map { $0 + [$0[0] + dx, $0[1] + dy] }
        preview.selectedSpot = list.count + new.count - 1
    }
}

/// Masks tab: the selected mask on the photo. Brush: paint (or erase) over the photo, shown in red. Linear: drag the
/// handle on either line, or anywhere else to move it. Radial: drag a handle on the edge to resize, the one above it to
/// rotate, anywhere else to move.
struct MaskOverlay: View {
    @Binding var masks: [LocalMask]?
    let map: PhotoMap
    let preview: Preview
    @State private var run: [CGPoint] = []
    @State private var grab: (handle: Int, start: [Double])?  // handle -1 moves the whole shape
    @State private var hover: CGPoint?

    var body: some View {
        if let i = preview.selectedMask, let list = masks, list.indices.contains(i) {
            let m = list[i], brush = map.length(preview.brushSize)
            Canvas { ctx, size in
                switch m.kind {
                case .brush: drawBrush(&ctx, size, m, brush)
                case .linear: drawLinear(&ctx, size, m.shape)
                case .radial: drawRadial(&ctx, m)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { if case .active(let p) = $0 { hover = p } else { hover = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.kind == .brush {
                        if run.isEmpty || hypot(v.location.x - run.last!.x, v.location.y - run.last!.y) >= max(2, brush / 3) { run.append(v.location) }
                        return
                    }
                    if grab == nil { grab = (handles(m).firstIndex { hypot($0.x - v.startLocation.x, $0.y - v.startLocation.y) < 10 } ?? -1, m.shape) }
                    if let g = grab { set(i, dragged(m.kind, g.handle, g.start, v)) }
                }
                .onEnded { _ in
                    if m.kind == .brush, !run.isEmpty {  // a stroke is committed (and undone) as a whole
                        let r = preview.erasing ? -preview.brushSize : preview.brushSize
                        set(i, m.shape + run.flatMap { p -> [Double] in let q = map.photo(p); return [q.x, q.y, r] })
                    }
                    run = []; grab = nil
                })
        }
    }

    private func set(_ i: Int, _ shape: [Double]) {
        guard var list = masks, list.indices.contains(i), list[i].shape != shape else { return }
        list[i].shape = shape
        masks = list
    }

    /// Linear: the two points. Radial: the edge handles right, bottom, left, top (along its turned axes), then the rotate
    /// handle just beyond the top one.
    private func handles(_ m: LocalMask) -> [CGPoint] {
        let s = m.shape
        switch m.kind {
        case .linear: return [map.view(s[0], s[1]), map.view(s[2], s[3])]
        case .radial:
            let a = m.angle, c = map.view(s[0], s[1]), top = radialPoint(s, a, 0, -s[3])
            let d = max(hypot(top.x - c.x, top.y - c.y), 1)
            return [radialPoint(s, a, s[2], 0), radialPoint(s, a, 0, s[3]), radialPoint(s, a, -s[2], 0), top,
                    CGPoint(x: top.x + (top.x - c.x) / d * 24, y: top.y + (top.y - c.y) / d * 24)]
        case .brush: return []
        }
    }

    /// A point `(u, v)` along the radial mask's own (turned by `angle` degrees) axes, in fractions of the photo's shorter side.
    private func radialPoint(_ s: [Double], _ angle: Double, _ u: Double, _ v: Double) -> CGPoint {
        let a = angle * .pi / 180
        return map.view(s[0], s[1], plus: u * cos(a) - v * sin(a), u * sin(a) + v * cos(a))
    }

    private func dragged(_ kind: MaskKind, _ h: Int, _ s0: [Double], _ v: DragGesture.Value) -> [Double] {
        var s = s0
        let d = map.delta(v.startLocation, v.location)
        switch (kind, h) {
        case (.linear, 0), (.linear, 1): s[2 * h] += d.x; s[2 * h + 1] += d.y
        case (.radial, 0...3):  // resize along the ellipse's own axes
            let u = map.units((s0[0], s0[1]), v.location), a = (s0.count > 4 ? s0[4] : 0) * .pi / 180
            if h % 2 == 0 { s[2] = max(0.01, abs(u.x * cos(a) + u.y * sin(a))) } else { s[3] = max(0.01, abs(u.y * cos(a) - u.x * sin(a))) }
        case (.radial, 4):  // rotate: the top handle follows the pointer, in whole degrees
            let u = map.units((s0[0], s0[1]), v.location)
            var deg = (atan2(u.y, u.x) * 180 / .pi + 90).rounded()
            if deg > 180 { deg -= 360 }
            if s.count > 4 { s[4] = deg } else { s.append(deg) }
        default: s[0] += d.x; s[1] += d.y; if kind == .linear { s[2] += d.x; s[3] += d.y }
        }
        return s
    }

    private func drawBrush(_ ctx: inout GraphicsContext, _ size: CGSize, _ m: LocalMask, _ brush: CGFloat) {
        let f = max(0.01, (m.feather ?? 50) / 100)  // the soft outer part of each dab, as maskPlane renders it
        if preview.maskOverlay {
            let inv = m.invert == true
            let soft = Gradient(stops: [.init(color: .red, location: 0), .init(color: .red, location: 1 - f),
                                        .init(color: .red.opacity(0.5), location: 1 - f / 2), .init(color: .red.opacity(0), location: 1)])
            ctx.opacity = 0.4
            ctx.drawLayer { l in
                func dab(_ c: CGPoint, _ r: CGFloat, erase: Bool) {
                    l.blendMode = erase != inv ? .destinationOut : .normal
                    l.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .radialGradient(soft, center: c, startRadius: 0, endRadius: r))
                }
                if inv { l.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red)) }
                for k in stride(from: 0, to: m.shape.count - 2, by: 3) {
                    dab(map.view(m.shape[k], m.shape[k + 1]), map.length(abs(m.shape[k + 2])), erase: m.shape[k + 2] < 0)
                }
                for p in run { dab(p, brush, erase: preview.erasing) }
            }
            ctx.opacity = 1
        }
        if let hover {  // Lightroom's two circles: the brush, and where its feathered edge begins
            ring(&ctx, hover, brush, width: 1, dash: preview.erasing ? [3, 3] : [], alpha: 0.9)
            if f < 0.98 { ring(&ctx, hover, brush * (1 - f), width: 1, dash: [2, 3], alpha: 0.6) }
        }
    }

    /// Lightroom's three lines: full effect, middle, no effect.
    private func drawLinear(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: [Double]) {
        let a = map.view(s[0], s[1]), b = map.view(s[2], s[3]), d = max(hypot(b.x - a.x, b.y - a.y), 1)
        let n = CGPoint(x: -(b.y - a.y) / d * 4000, y: (b.x - a.x) / d * 4000), mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        for (p, dash) in [(a, [CGFloat]()), (mid, [5, 4]), (b, [])] {
            line(&ctx, CGPoint(x: p.x - n.x, y: p.y - n.y), CGPoint(x: p.x + n.x, y: p.y + n.y), width: 1, dash: dash)
        }
        line(&ctx, a, b, width: 1, dash: [2, 3])
        handle(&ctx, a); handle(&ctx, b, 4)
    }

    private func drawRadial(_ ctx: inout GraphicsContext, _ m: LocalMask) {
        let s = m.shape, f = (m.feather ?? 50) / 100
        for (k, dash) in [(1.0, [CGFloat]()), (1 - f, [4, 4])] where k > 0.02 {
            var p = Path()
            for t in 0...72 {
                let a = Double(t) * .pi / 36, q = radialPoint(s, m.angle, s[2] * k * cos(a), s[3] * k * sin(a))
                t == 0 ? p.move(to: q) : p.addLine(to: q)
            }
            ctx.stroke(p, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 2.5, dash: dash))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
        handle(&ctx, map.view(s[0], s[1]), 4)
        let hs = handles(m)
        line(&ctx, hs[3], hs[4], width: 1)
        for h in hs.prefix(4) { handle(&ctx, h) }
        ring(&ctx, hs[4], 5, width: 2)  // rotate
        handle(&ctx, hs[4], 2.5)
    }
}

/// Red, green and blue histogram, mixed additively like Lightroom's.
struct HistogramView: View {
    let bins: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            guard bins.count == 4 else { return }
            ctx.blendMode = .plusLighter
            for (k, color) in [Color.red, Color.green, Color.blue].enumerated() {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 { path.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(bins[k][i]) * 0.95))) }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(0.6)))
            }
        }
        .frame(height: 70)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Histogram")
    }
}
