// The canvas: before and after (side by side or after only), zoom and pan, the crop box, and the histogram.
import AppKit
import SwiftUI

/// Before and after, zoomed and panned together. Pinch or ⌘= / ⌘− to zoom, hold Space and drag to pan.
/// In crop mode it shows the whole straightened frame with the crop box over it.
struct CompareView: View {
    let preview: Preview
    let single: Bool  // after only, full width
    @Binding var crop: [Double]?
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
                panel(preview.cropMode ? "Crop" : holding ? "Without edits" : onePane ? "Hold to compare" : "After  ·  hold to compare",
                      holding ? preview.before : preview.after)
                    .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: { holding = $0 && !space && !preview.cropMode })
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

    private func panel(_ title: String, _ img: CGImage?) -> some View {
        ZStack {
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width * zoom, height: fit.height * zoom)
                    .overlay { if preview.cropMode { CropOverlay(crop: $crop, size: fit, aspect: preview.cropAspect, frameAspect: fit.width / max(fit.height, 1)) } }
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
