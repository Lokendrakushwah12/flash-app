// Lightroom-style develop stages that run after the flash look (Engine.swift). All of them are app-only, off by
// default (nil), deterministic, and scale with the photo (s = min(H, W) / 720) so previews match exports.
import Accelerate
import Foundation

/// Retouching, then Light, Tone Curve, Presence, Color Mixer, Color Grading, Blur, Detail and Effects.
func develop(_ x0: RGB, _ img: RGB, _ Mr: [Float], _ faces: [Face], _ p: Params, _ s: Double) -> RGB {
    var x = x0
    if let t = p.plastic, t != 0 { x = plasticSkin(x, skinMask(img, Mr, faces, s), Float(t / 100), s) }
    if let t = p.lips, t != 0 { x = pinkLips(x, faces, Float(t / 100), s) }
    x = light(x, p, s)
    x = toneCurves(x, p)
    x = presence(x, p, s)
    if p.look.hsl_hue != nil || p.look.hsl_sat != nil || p.look.hsl_lum != nil { x = colorMixer(x, p) }
    x = colorGrade(x, p)
    x = backgroundBlur(x, Mr, p, s)
    x = sharpen(x, p, s)
    x = vignette(x, p)
    x = grain(x, p, s)
    return x.map { _, r, g, b in (clip01(r), clip01(g), clip01(b)) }
}

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = clip01((x - a) / (b - a)); return t * t * (3 - 2 * t) }

/// All visible skin of the person: hands, arms and neck (edit's body mask) plus the faces.
func skinMask(_ img: RGB, _ Mr: [Float], _ faces: [Face], _ s: Double) -> [Float] {
    let (W, H, n) = (img.w, img.h, img.n), sw = skinWeight(img)
    let body0 = img.plane { i in sw[i] * clip01((img.r[i] - img.b[i] - 0.11) / 0.04) * clip01((luma(img.r[i], img.g[i], img.b[i]) - 0.33) / 0.08) }
    let fm = faces.map { faceMask(W, H, $0, Mr) }, body = gauss(body0, W, H, s), swb = gauss(sw, W, H, 1.5 * s)
    return fill(n) { i in min(1, fm.reduce(body[i] * Mr[i]) { $0 * (1 - $1[i]) } + fm.reduce(0) { $0 + $1[i] * swb[i] }) }
}

// MARK: - Light: exposure, contrast, highlights, shadows, whites, blacks

/// Works on luminance and scales colour by the same ratio, so hues hold. Highlights and shadows are chosen from a
/// blurred copy, so they lift or recover whole areas instead of flattening fine detail.
func light(_ x: RGB, _ p: Params, _ s: Double) -> RGB {
    let ev = Float(p.exposure ?? 0), c = Float((p.contrast ?? 0) / 100), hi = Float((p.highlights ?? 0) / 100)
    let sh = Float((p.shadows ?? 0) / 100), wh = Float((p.whites ?? 0) / 100), bl = Float((p.blacks ?? 0) / 100)
    if ev == 0 && c == 0 && hi == 0 && sh == 0 && wh == 0 && bl == 0 { return x }
    let gain = exp2f(ev), y0 = x.lumaPlane
    let y1 = fill(x.n) { srgb(lin(y0[$0]) * gain) }  // exposure, in linear light
    let base = hi != 0 || sh != 0 ? gauss(y1, x.w, x.h, 10 * s) : y1
    return x.map { i, r, g, b in
        var y = y1[i]
        let area = 0.5 * (base[i] + y1[i])  // half local: whole areas move together, without halos around edges
        y *= exp2f(hi * 0.5 * smoothstep(0.6, 1.0, area) + sh * 0.9 * (1 - smoothstep(0.0, 0.45, area)))
        y += wh * 0.15 * smoothstep(0.55, 1, y) + bl * 0.12 * (1 - smoothstep(0, 0.4, y))
        if c > 0 { let t = clip01(y); y += (t * t * (3 - 2 * t) - y) * c * 0.9 } else if c < 0 { y = 0.5 + (y - 0.5) * (1 + c * 0.5) }
        let k = y / max(y0[i], 1e-4)
        return (r * k, g * k, b * k)
    }
}

/// Auto (like Lightroom's Auto button): settings that bring this picture to a balanced exposure and full range.
/// Measured on the current result, so it returns changes to add to the current Light settings.
func autoTone(_ x: RGB) -> (exposure: Double, contrast: Double, highlights: Double, shadows: Double, whites: Double, blacks: Double) {
    var y = x.lumaPlane
    vDSP_vsort(&y, vDSP_Length(y.count), 1)
    func q(_ f: Double) -> Float { y[min(y.count - 1, Int(Double(y.count - 1) * f))] }
    let mean = y.reduce(0, +) / Float(y.count)
    let ev = Double(log2(lin(0.46) / max(lin(mean), 1e-4))).clamped(-2, 2)
    let hiFrac = Double(y.count - (y.firstIndex { $0 > 0.95 } ?? y.count)) / Double(y.count)
    let loFrac = Double(y.firstIndex { $0 >= 0.08 } ?? y.count) / Double(y.count)
    let spread = Double(q(0.9) - q(0.1))
    return (ev * 0.8, spread < 0.45 ? 20 : spread > 0.75 ? -10 : 0, hiFrac > 0.02 ? -40 : 0, loFrac > 0.08 ? 35 : 0,
            q(0.995) < 0.95 ? min(60, Double(0.97 - q(0.995)) * 300) : 0, q(0.005) > 0.04 ? -min(50, Double(q(0.005) - 0.02) * 400) : 0)
}

extension Double { func clamped(_ a: Double, _ b: Double) -> Double { Swift.min(Swift.max(self, a), b) } }

// MARK: - Tone curve

/// A monotone cubic through user points (scipy PCHIP rules, any spacing), sampled into a 1024-entry table.
struct PointCurve {
    let lut: [Float]

    init?(_ flat: [Double]?) {
        guard let flat, flat.count >= 4, flat != [0, 0, 1, 1] else { return nil }
        let pts = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0].clamped(0, 1), flat[$0 + 1].clamped(0, 1)) }.sorted { $0.0 < $1.0 }
        var xs = [Double](), ys = [Double]()
        for (a, b) in pts where xs.last.map({ a - $0 > 1e-4 }) ?? true { xs.append(a); ys.append(b) }
        guard xs.count >= 2 else { return nil }
        let n = xs.count, h = (0..<n - 1).map { xs[$0 + 1] - xs[$0] }, m = (0..<n - 1).map { (ys[$0 + 1] - ys[$0]) / h[$0] }
        func sgn(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }
        var d = [Double](repeating: 0, count: n)
        if n == 2 { d = [m[0], m[0]] } else {
            for k in 1..<n - 1 where sgn(m[k]) == sgn(m[k - 1]) && m[k] != 0 && m[k - 1] != 0 {
                let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
                d[k] = (w1 + w2) / (w1 / m[k - 1] + w2 / m[k])
            }
            func edge(_ h0: Double, _ h1: Double, _ m0: Double, _ m1: Double) -> Double {
                let e = ((2 * h0 + h1) * m0 - h0 * m1) / (h0 + h1)
                if sgn(e) != sgn(m0) { return 0 }
                return sgn(m0) != sgn(m1) && abs(e) > 3 * abs(m0) ? 3 * m0 : e
            }
            d[0] = edge(h[0], h[1], m[0], m[1]); d[n - 1] = edge(h[n - 2], h[n - 3], m[n - 2], m[n - 3])
        }
        lut = (0..<1024).map { i in
            let x = Double(i) / 1023
            if x <= xs[0] { return Float(ys[0]) }
            if x >= xs[n - 1] { return Float(ys[n - 1]) }
            var k = 0
            while k < n - 2 && x > xs[k + 1] { k += 1 }
            let t = x - xs[k], c3 = (d[k] + d[k + 1] - 2 * m[k]) / h[k]
            return Float(((c3 / h[k] * t + ((m[k] - d[k]) / h[k] - c3)) * t + d[k]) * t + ys[k])
        }
    }

    @inline(__always) func callAsFunction(_ v: Float) -> Float {
        let f = clip01(v) * 1023, i = min(Int(f), 1022), t = f - Float(i)
        return lut[i] + (lut[i + 1] - lut[i]) * t
    }
}

/// The main curve on every channel, then the red, green and blue curves.
func toneCurves(_ x: RGB, _ p: Params) -> RGB {
    let all = PointCurve(p.curve), cr = PointCurve(p.curve_r), cg = PointCurve(p.curve_g), cb = PointCurve(p.curve_b)
    if all == nil && cr == nil && cg == nil && cb == nil { return x }
    return x.map { _, r, g, b in
        var (R, G, B) = all.map { ($0(r), $0(g), $0(b)) } ?? (r, g, b)
        if let cr { R = cr(R) }
        if let cg { G = cg(G) }
        if let cb { B = cb(B) }
        return (R, G, B)
    }
}

// MARK: - Presence: texture, clarity, vibrance, saturation

func presence(_ x: RGB, _ p: Params, _ s: Double) -> RGB {
    let tex = Float((p.texture ?? 0) / 100), cla = Float((p.clarity_all ?? 0) / 100)
    let vib = Float((p.vibrance ?? 0) / 100), sat = Float((p.saturation ?? 0) / 100)
    var out = x
    if tex != 0 || cla != 0 {  // texture: fine detail; clarity: broad midtone contrast
        let y = x.lumaPlane, fine = tex != 0 ? gauss(y, x.w, x.h, 1.5 * s) : y, broad = cla != 0 ? gauss(y, x.w, x.h, 12 * s) : y
        out = x.map { i, r, g, b in
            let mid = 1 - (2 * y[i] - 1) * (2 * y[i] - 1)
            let d = tex * 1.2 * (y[i] - fine[i]) + cla * 0.8 * (y[i] - broad[i]) * mid
            return (r + d, g + d, b + d)
        }
    }
    if vib != 0 || sat != 0 {  // vibrance lifts muted colours most and spares skin tones
        out = out.map { _, r, g, b in
            let y = luma(r, g, b), mx = max(r, g, b), cs = mx > 1e-4 ? (mx - min(r, g, b)) / mx : 0
            let warm = clip01((r - b) / 0.15) * clip01((r - g) / 0.12) * clip01((0.6 - cs) / 0.3)
            let k = 1 + sat + vib * (1 - cs) * (1 - 0.6 * warm)
            return (y + (r - y) * k, y + (g - y) * k, y + (b - y) * k)
        }
    }
    return out
}

// MARK: - Color grading: shadows, midtones and highlights wheels

func colorGrade(_ x: RGB, _ p: Params) -> RGB {
    let wheels = [p.grade_shadows, p.grade_midtones, p.grade_highlights]
    if wheels.allSatisfy({ $0 == nil }) { return x }
    // each wheel pushes towards its hue (its colour minus its own luminance) and brightens or darkens its range
    let t: [(Float, Float, Float, Float)] = wheels.map { w in
        guard let w, w.count == 3 else { return (0, 0, 0, 0) }
        let (r, g, b) = hsv2rgb(Float(w[0]), 1, 1), y = luma(r, g, b), k = Float(w[1] / 100) * 0.3
        return ((r - y) * k, (g - y) * k, (b - y) * k, Float(w[2] / 100))
    }
    let bal = Float((p.grade_balance ?? 0) / 100) * 0.3
    return x.map { _, r, g, b in
        let y = clip01(luma(r, g, b) - bal), ws = (1 - y) * (1 - y), wh = y * y, wm = max(0, 1 - ws - wh)
        var R = r + t[0].0 * ws + t[1].0 * wm + t[2].0 * wh
        var G = g + t[0].1 * ws + t[1].1 * wm + t[2].1 * wh
        var B = b + t[0].2 * ws + t[1].2 * wm + t[2].2 * wh
        let e = exp2f(0.6 * (t[0].3 * ws + t[1].3 * wm + t[2].3 * wh))
        R *= e; G *= e; B *= e
        return (R, G, B)
    }
}

// MARK: - Background blur: gaussian, lens (round bokeh), motion, zoom, tilt-shift

enum BlurKind: String, CaseIterable { case lens, gaussian, motion, zoom, tiltshift }

/// The person stays sharp: the background is blurred as blur(colour × background) / blur(background), so the person
/// never smears into it. Blurs run at reduced resolution (the radius shrinks with it), so big blurs stay fast.
func backgroundBlur(_ x: RGB, _ Mr: [Float], _ p: Params, _ s: Double) -> RGB {
    guard let amount = p.blur, amount > 0 else { return x }
    let kind = BlurKind(rawValue: p.blur_type ?? "lens") ?? .lens, (w, h, n) = (x.w, x.h, x.n)
    let radius = Float(amount / 100 * 28 * s), f = max(1, Int(radius / 6)), (sw, sh) = ((w + f - 1) / f, (h + f - 1) / f)
    let r = max(1, radius / Float(f)), bokeh = Float((p.blur_bokeh ?? 30) / 100)
    let bgw = fill(n) { 1 - Mr[$0] }
    // the person's centre, for zoom blur and the default tilt-shift band
    var (mx, my, mw) = (0.0, 0.0, 0.0)
    for i in stride(from: 0, to: n, by: 7) where Mr[i] > 0.5 { mx += Double(i % w); my += Double(i / w); mw += 1 }
    let (cx, cy) = mw > 0 ? (mx / mw, my / mw) : (Double(w) / 2, Double(h) / 2)
    let disc = discKernel(r), line = lineKernel(r * 1.6, Float((p.blur_angle ?? 0) * .pi / 180))
    let op: ([Float]) -> [Float] = { plane in
        switch kind {
        case .gaussian, .tiltshift: return gauss(plane, sw, sh, Double(r) / 2)
        case .lens: return convolve(plane, sw, sh, disc)
        case .motion: return convolve(plane, sw, sh, line)
        case .zoom: return zoomBlur(plane, sw, sh, Float(cx) / Float(f), Float(cy) / Float(f), Float(amount / 100) * 0.3)
        }
    }
    // lens and gaussian blur mix light like a real lens: in linear light, with highlights boosted into bokeh discs
    let boost = kind == .lens ? bokeh * 3 : 0
    let planes = [x.r, x.g, x.b].map { c in fill(n) { let v = lin(c[$0]); return v * (1 + boost * powf(clip01((v - 0.5) / 0.5), 2)) * bgw[$0] } }
    let wsmall = op(downsample(bgw, w, h, f))
    let blurred = planes.map { pl -> [Float] in
        let b = op(downsample(pl, w, h, f))
        return upsample(fill(sw * sh) { b[$0] / max(wsmall[$0], 1e-3) }, sw, sh, w, h, f)
    }
    let focus = Float(p.blur_focus ?? cy / Double(h))  // tilt-shift: the sharp band's height, 0 top ... 1 bottom
    return x.map { i, R, G, B in
        var t = 1 - Mr[i]
        if kind == .tiltshift { t *= smoothstep(0.06, 0.32, abs(Float(i / w) / Float(h) - focus)) }
        return (R + (srgb(blurred[0][i]) - R) * t, G + (srgb(blurred[1][i]) - G) * t, B + (srgb(blurred[2][i]) - B) * t)
    }
}

/// Box-average shrink by an integer factor.
func downsample(_ x: [Float], _ w: Int, _ h: Int, _ f: Int) -> [Float] {
    if f == 1 { return x }
    let (sw, sh) = ((w + f - 1) / f, (h + f - 1) / f)
    return fill(sw * sh) { j in
        let (X, Y) = (j % sw, j / sw)
        var sum: Float = 0, cnt: Float = 0
        for y in Y * f ..< min(h, Y * f + f) { for xx in X * f ..< min(w, X * f + f) { sum += x[y * w + xx]; cnt += 1 } }
        return sum / cnt
    }
}

/// Bilinear growth back to full size.
func upsample(_ x: [Float], _ sw: Int, _ sh: Int, _ w: Int, _ h: Int, _ f: Int) -> [Float] {
    if f == 1 { return x }
    return fill(w * h) { i in
        let fx = max(0, min(Float(sw - 1), (Float(i % w) + 0.5) / Float(f) - 0.5)), fy = max(0, min(Float(sh - 1), (Float(i / w) + 0.5) / Float(f) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1), tx = fx - Float(x0), ty = fy - Float(y0)
        let a = x[y0 * sw + x0] + (x[y0 * sw + x1] - x[y0 * sw + x0]) * tx, b = x[y1 * sw + x0] + (x[y1 * sw + x1] - x[y1 * sw + x0]) * tx
        return a + (b - a) * ty
    }
}

struct Kernel { let values: [Float], size: Int }

/// A round aperture with a soft one-pixel rim: lens blur's bokeh shape.
func discKernel(_ r: Float) -> Kernel {
    let R = Int(ceil(r)), size = 2 * R + 1
    var k = (0..<size * size).map { i -> Float in
        let dx = Float(i % size - R), dy = Float(i / size - R)
        return clip01(r + 0.5 - (dx * dx + dy * dy).squareRoot())
    }
    let sum = k.reduce(0, +); k = k.map { $0 / sum }
    return Kernel(values: k, size: size)
}

/// A line at `angle`: motion blur.
func lineKernel(_ r: Float, _ angle: Float) -> Kernel {
    let R = Int(ceil(r)), size = 2 * R + 1
    var k = [Float](repeating: 0, count: size * size)
    for t in stride(from: -r, through: r, by: 0.25) {
        let px = Int((Float(R) + t * cosf(angle)).rounded()), py = Int((Float(R) - t * sinf(angle)).rounded())
        if (0..<size).contains(px), (0..<size).contains(py) { k[py * size + px] += 1 }
    }
    let sum = k.reduce(0, +); k = k.map { $0 / sum }
    return Kernel(values: k, size: size)
}

func convolve(_ x: [Float], _ w: Int, _ h: Int, _ k: Kernel) -> [Float] {
    var src = x, dst = [Float](repeating: 0, count: w * h)
    src.withUnsafeMutableBufferPointer { sp in
        dst.withUnsafeMutableBufferPointer { dp in
            var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageConvolve_PlanarF(&s, &d, nil, 0, 0, k.values, UInt32(k.size), UInt32(k.size), 0, vImage_Flags(kvImageEdgeExtend))
        }
    }
    return dst
}

/// Streaks towards (cx, cy), like zooming the lens during the exposure.
func zoomBlur(_ x: [Float], _ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ strength: Float) -> [Float] {
    let steps = 24
    return fill(w * h) { i in
        let px = Float(i % w), py = Float(i / w)
        var sum: Float = 0
        for k in 0..<steps {
            let t = 1 - strength * Float(k) / Float(steps - 1)
            let sx = min(max(cx + (px - cx) * t, 0), Float(w - 1)), sy = min(max(cy + (py - cy) * t, 0), Float(h - 1))
            sum += x[Int(sy) * w + Int(sx)]
        }
        return sum / Float(steps)
    }
}

// MARK: - Detail: sharpening and noise reduction

/// Unsharp mask on luminance; Masking keeps flat areas (skin, sky) smooth by sharpening only real edges.
func sharpen(_ x: RGB, _ p: Params, _ s: Double) -> RGB {
    guard let a = p.sharpen, a > 0 else { return x }
    let y = x.lumaPlane, base = gauss(y, x.w, x.h, (p.sharpen_radius ?? 1) * s), k = Float(a / 100) * 1.4
    let thr = Float((p.sharpen_masking ?? 0) / 100) * 0.05
    let edge = thr > 0 ? gauss(fill(x.n) { abs(y[$0] - base[$0]) }, x.w, x.h, s) : []
    return x.map { i, r, g, b in
        let d = (y[i] - base[i]) * k * (thr > 0 ? smoothstep(thr * 0.5, thr * 1.5, edge[i]) : 1)
        return (r + d, g + d, b + d)
    }
}

/// Luminance noise: an edge-preserving self-guided filter. Colour noise: the chroma is blurred, the detail kept.
func denoise(_ x: RGB, _ p: Params, _ s: Double) -> RGB {
    let ln = Float((p.denoise ?? 0) / 100), cn = Float((p.denoise_color ?? 0) / 100)
    if ln <= 0 && cn <= 0 { return x }
    var out = x
    if ln > 0 {
        let sm = skinSmooth(x, max(1, Int((1.5 * s).rounded())), 0.0004 + ln * ln * 0.012)
        out = x.map { i, r, g, b in (r + (sm.r[i] - r) * ln, g + (sm.g[i] - g) * ln, b + (sm.b[i] - b) * ln) }
    }
    if cn > 0 {
        let y = out.lumaPlane, sig = Double(cn) * 4 * s
        let c = [out.r, out.g, out.b].map { ch in gauss(fill(out.n) { ch[$0] - y[$0] }, out.w, out.h, sig) }
        out = out.map { i, _, _, _ in (y[i] + c[0][i], y[i] + c[1][i], y[i] + c[2][i]) }
    }
    return out
}

// MARK: - Effects: vignette and grain

/// Post-crop vignette: centred on the crop so it frames the final picture. Negative darkens the corners.
func vignette(_ x: RGB, _ p: Params) -> RGB {
    guard let a0 = p.vignette, a0 != 0 else { return x }
    let a = Float(a0 / 100), mid = Float((p.vignette_midpoint ?? 50) / 100), fe = Float((p.vignette_feather ?? 50) / 100)
    let rnd = Float((p.vignette_roundness ?? 0) / 100), c = p.crop ?? [0, 0, 1, 1], (W, H) = (Float(x.w), Float(x.h))
    let cx = Float(c[0] + c[2] / 2) * W, cy = Float(c[1] + c[3] / 2) * H, hw = Float(c[2]) * W / 2, hh = Float(c[3]) * H / 2, m = min(hw, hh)
    let r0 = 0.3 + mid * 0.9, r1 = r0 + 0.1 + fe * 0.9, pw = 2 + max(0, -rnd) * 6  // negative roundness: squarer
    return x.map { i, r, g, b in
        let dx = Float(i % x.w) - cx, dy = Float(i / x.w) - cy
        let frame = powf(powf(abs(dx / hw), pw) + powf(abs(dy / hh), pw), 1 / pw), circle = (dx * dx + dy * dy).squareRoot() / m
        let t = smoothstep(r0, r1, frame + (circle - frame) * max(0, rnd))
        if a < 0 { let k = 1 + a * t; return (r * k, g * k, b * k) }
        let k = a * t
        return (r + (1 - r) * k, g + (1 - g) * k, b + (1 - b) * k)
    }
}

/// Film grain from a fixed hash, so the same photo always gets the same grain; strongest in the midtones.
func grain(_ x: RGB, _ p: Params, _ s: Double) -> RGB {
    guard let a0 = p.grain, a0 > 0 else { return x }
    let a = Float(a0 / 100) * 0.14, cell = max(0.6, Float((p.grain_size ?? 25) / 25)) * Float(s)
    @inline(__always) func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Float((h ^ (h >> 16)) & 0xFFFF) / 32767.5 - 1
    }
    @inline(__always) func noise(_ fx: Float, _ fy: Float) -> Float {
        let ix = Int(floor(fx)), iy = Int(floor(fy)), tx = fx - floor(fx), ty = fy - floor(fy)
        let top = hash(ix, iy) + (hash(ix + 1, iy) - hash(ix, iy)) * tx, bottom = hash(ix, iy + 1) + (hash(ix + 1, iy + 1) - hash(ix, iy + 1)) * tx
        return top + (bottom - top) * ty
    }
    return x.map { i, r, g, b in
        let fx = Float(i % x.w) / cell, fy = Float(i / x.w) / cell
        let n = 0.65 * noise(fx, fy) + 0.35 * noise(fx * 2.1 + 17, fy * 2.1 + 31), y = luma(r, g, b)
        let k = a * n * (0.35 + 0.65 * (1 - abs(2 * y - 1)))
        return (r + k, g + k, b + k)
    }
}

// MARK: - Geometry: flip, quarter turns, straighten, crop

/// Applied after the edit, to before and after alike. Straightening scales up just enough that no empty corners show.
/// `crop: false` shows the whole straightened frame (for editing the crop box).
func geometry(_ x: RGB, _ p: Params, crop useCrop: Bool = true) -> RGB {
    let quarter = ((Int(((p.rotate ?? 0) / 90).rounded()) % 4) + 4) % 4, flip = (p.flip ?? 0) != 0
    let theta = Float((p.straighten ?? 0) * .pi / 180), c = useCrop ? (p.crop ?? [0, 0, 1, 1]) : [0, 0, 1, 1]
    if quarter == 0 && !flip && theta == 0 && c == [0, 0, 1, 1] { return x }
    let (W, H) = quarter % 2 == 0 ? (Float(x.w), Float(x.h)) : (Float(x.h), Float(x.w))
    let cs = cosf(abs(theta)), sn = sinf(abs(theta)), k = max((W * cs + H * sn) / W, (W * sn + H * cs) / H)
    let ow = max(1, Int((c[2] * Double(W)).rounded())), oh = max(1, Int((c[3] * Double(H)).rounded()))
    let ox = Float(c[0]) * W, oy = Float(c[1]) * H, (cx, cy) = (W / 2, H / 2), (ct, st) = (cosf(theta), sinf(theta))
    let (sw, sh) = (Float(x.w), Float(x.h))
    func sample(_ ch: [Float], _ px: Float, _ py: Float) -> Float {
        let fx = min(max(px - 0.5, 0), sw - 1), fy = min(max(py - 0.5, 0), sh - 1)
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, x.w - 1), y1 = min(y0 + 1, x.h - 1), tx = fx - Float(x0), ty = fy - Float(y0)
        let a = ch[y0 * x.w + x0] + (ch[y0 * x.w + x1] - ch[y0 * x.w + x0]) * tx, b = ch[y1 * x.w + x0] + (ch[y1 * x.w + x1] - ch[y1 * x.w + x0]) * tx
        return a + (b - a) * ty
    }
    // output pixel -> straightened frame -> turned-and-flipped frame -> original photo
    func source(_ i: Int) -> (Float, Float) {
        let X = ox + Float(i % ow) + 0.5 - cx, Y = oy + Float(i / ow) + 0.5 - cy
        var fx = (X * ct + Y * st) / k + cx, fy = (-X * st + Y * ct) / k + cy
        if flip { fx = W - fx }
        switch quarter {
        case 1: return (fy, sh - fx)
        case 2: return (sw - fx, sh - fy)
        case 3: return (sw - fy, fx)
        default: return (fx, fy)
        }
    }
    let src = fill(ow * oh) { Float(source($0).0) }, srcY = fill(ow * oh) { Float(source($0).1) }
    func ch(_ c: [Float]) -> [Float] { fill(ow * oh) { sample(c, src[$0], srcY[$0]) } }
    return RGB(w: ow, h: oh, r: ch(x.r), g: ch(x.g), b: ch(x.b))
}

// MARK: - Histogram

/// 256-bin red, green, blue and luminance counts, normalised so the tallest bin (ignoring the clipped ends) is 1.
func histogram(_ x: RGB) -> [[Float]] {
    var bins = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 4)
    for i in stride(from: 0, to: x.n, by: max(1, x.n / 400_000)) {
        let r = clip01(x.r[i]), g = clip01(x.g[i]), b = clip01(x.b[i])
        bins[0][Int(r * 255)] += 1; bins[1][Int(g * 255)] += 1; bins[2][Int(b * 255)] += 1; bins[3][Int(luma(r, g, b) * 255)] += 1
    }
    let top = max(1, bins.map { $0[2..<254].max() ?? 1 }.max() ?? 1)
    return bins.map { $0.map { min(1, $0 / top) } }
}
