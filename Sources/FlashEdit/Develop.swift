// Lightroom-style develop stages that run after the flash look (Engine.swift). All of them are app-only, off by
// default (nil), deterministic, and scale with the photo (s = min(H, W) / 720) so previews match exports.
import Accelerate
import Foundation

/// Retouching, then Light, Masks, Tone Curve, Presence, Color Mixer, Color Grading, Blur, Detail and Effects.
func develop(_ x0: RGB, _ img: RGB, _ Mr: [Float], _ faces: [Face], _ p: Params, _ s: Double) -> RGB {
    var x = x0
    if let t = p.plastic, t != 0 { x = plasticSkin(x, skinMask(img, Mr, faces, s), Float(t / 100), s) }
    if let t = p.lips, t != 0 { x = pinkLips(x, faces, Float(t / 100), s) }
    x = light(x, p, s)
    x = localMasks(x, p, s)
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
/// `center` (pixels) overrides the person's centre for zoom blur and the tilt-shift band (masks blur around their own centre).
func backgroundBlur(_ x: RGB, _ Mr: [Float], _ p: Params, _ s: Double, center: (Double, Double)? = nil) -> RGB {
    guard let amount = p.blur, amount > 0 else { return x }
    let kind = BlurKind(rawValue: p.blur_type ?? "lens") ?? .lens, (w, h, n) = (x.w, x.h, x.n)
    let radius = Float(amount / 100 * 28 * s), f = max(1, Int(radius / 6)), (sw, sh) = ((w + f - 1) / f, (h + f - 1) / f)
    let r = max(1, radius / Float(f)), bokeh = Float((p.blur_bokeh ?? 30) / 100)
    let bgw = fill(n) { 1 - Mr[$0] }
    // the person's centre, for zoom blur and the default tilt-shift band
    var (mx, my, mw) = (0.0, 0.0, 0.0)
    for i in stride(from: 0, to: n, by: 7) where Mr[i] > 0.5 { mx += Double(i % w); my += Double(i / w); mw += 1 }
    let (cx, cy) = center ?? (mw > 0 ? (mx / mw, my / mw) : (Double(w) / 2, Double(h) / 2))
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

// MARK: - Heal: spot removal

/// Fills each spot [x, y, r, sx, sy] from its source patch: the source's texture plus a smooth colour offset that makes it
/// match the spot's own surroundings at the edge (harmonic, so there is no seam), feathered over the outer third.
/// x, y and sx, sy are fractions of the photo's width and height, r a fraction of its shorter side, all before crop and
/// rotation, so a spot lands in the same place at any size. Spots apply in order, so later ones build on earlier ones.
func heal(_ x: RGB, _ spots: [[Double]]) -> RGB {
    var out = x
    let (w, h) = (x.w, x.h), side = Double(min(w, h)), n = 32
    for sp in spots where sp.count == 5 {
        let cx = Float(sp[0] * Double(w)), cy = Float(sp[1] * Double(h)), R = Float(max(1.5, sp[2] * side))
        let dx = Int(((sp[3] - sp[0]) * Double(w)).rounded()), dy = Int(((sp[4] - sp[1]) * Double(h)).rounded()), q = max(1, Int(R * 0.15))
        func mean(_ px: Float, _ py: Float) -> SIMD3<Float> {  // average colour in a small box, clamped to the photo
            let ix = min(max(Int(px), 0), w - 1), iy = min(max(Int(py), 0), h - 1)
            var sum = SIMD3<Float>(), cnt: Float = 0
            for y in max(0, iy - q)...min(h - 1, iy + q) {
                for xx in max(0, ix - q)...min(w - 1, ix + q) { sum += SIMD3(out.r[y * w + xx], out.g[y * w + xx], out.b[y * w + xx]); cnt += 1 }
            }
            return sum / cnt
        }
        // the colour step between the spot's edge and the source's edge, at n points round the circle
        let ring = (0..<n).map { k -> (x: Float, y: Float, d: SIMD3<Float>) in
            let a = Float(k) * 2 * .pi / Float(n), bx = cx + R * cosf(a), by = cy + R * sinf(a)
            return (bx, by, mean(bx, by) - mean(bx + Float(dx), by + Float(dy)))
        }
        let x0 = max(0, Int(cx - R)), x1 = min(w - 1, Int(cx + R)), y0 = max(0, Int(cy - R)), y1 = min(h - 1, Int(cy + R))
        guard x0 <= x1, y0 <= y1 else { continue }
        // the source patch is read before anything is written, since the two may overlap
        let bw = x1 - x0 + 1
        var patch = [SIMD3<Float>](repeating: .zero, count: bw * (y1 - y0 + 1))
        for y in y0...y1 {
            for xx in x0...x1 {
                let j = min(max(y + dy, 0), h - 1) * w + min(max(xx + dx, 0), w - 1)
                patch[(y - y0) * bw + xx - x0] = SIMD3(out.r[j], out.g[j], out.b[j])
            }
        }
        for y in y0...y1 {
            for xx in x0...x1 {
                let px = Float(xx) + 0.5, py = Float(y) + 0.5, a = 1 - smoothstep(0.65 * R, R, hypot(px - cx, py - cy))
                if a <= 0 { continue }
                // Poisson kernel of the disc: weights 1/|p - b|² interpolate the edge steps harmonically
                var d = SIMD3<Float>(), sw: Float = 0
                for b in ring { let wt = 1 / max((px - b.x) * (px - b.x) + (py - b.y) * (py - b.y), 1e-3); d += wt * b.d; sw += wt }
                let v = patch[(y - y0) * bw + xx - x0] + d / sw, i = y * w + xx
                out.r[i] += (clip01(v.x) - out.r[i]) * a; out.g[i] += (clip01(v.y) - out.g[i]) * a; out.b[i] += (clip01(v.z) - out.b[i]) * a
            }
        }
    }
    return out
}

/// Where new spots copy from, like Lightroom's automatic source: of the nearby offsets that keep every copy inside the
/// photo and off the spots, the one whose patch edges best match the spots' surroundings and whose inside looks most
/// like them (no edges, no other blemishes). Spots are [x, y, r, ...]; returns the offset in fractions of width and height.
func healOffset(_ x: RGB, _ spots: [[Double]]) -> (Double, Double) {
    let (w, h) = (Double(x.w), Double(x.h)), side = min(w, h)
    let c = spots.map { (x: $0[0] * w, y: $0[1] * h, r: max(1.5, $0[2] * side)) }
    let R = c.map(\.r).max() ?? 1, angles = (0..<16).map { Double($0) * .pi / 8 }
    func px(_ X: Double, _ Y: Double) -> SIMD3<Float> {
        let i = min(max(Int(Y), 0), x.h - 1) * x.w + min(max(Int(X), 0), x.w - 1)
        return SIMD3(x.r[i], x.g[i], x.b[i])
    }
    var best = (score: Double.infinity, dx: 2.5 * R, dy: 0.0)
    for d in [2.2, 3.0, 4.2, 6.0] {
        for a in angles {
            let dx = d * R * cos(a), dy = d * R * sin(a)
            var score = 0.0
            for s in c {
                let (sx, sy) = (s.x + dx, s.y + dy)
                if sx < s.r || sy < s.r || sx + s.r > w || sy + s.r > h { score += 1e6 }  // outside the photo
                if c.contains(where: { hypot(sx - $0.x, sy - $0.y) < s.r + $0.r }) { score += 1e6 }  // on a spot
                var around = SIMD3<Float>(), edge = 0.0
                for b in angles {  // the ring just outside the spot against the same ring round the source
                    let t = px(s.x + 1.2 * s.r * cos(b), s.y + 1.2 * s.r * sin(b)), u = px(sx + 1.2 * s.r * cos(b), sy + 1.2 * s.r * sin(b))
                    around += t; edge += Double(((t - u) * (t - u)).sum())
                }
                around /= 16
                var inside = 0.0
                for gy in -2...2 {  // the source's inside against the spot's surroundings
                    for gx in -2...2 { let v = px(sx + Double(gx) * 0.35 * s.r, sy + Double(gy) * 0.35 * s.r) - around; inside += Double((v * v).sum()) }
                }
                score += edge / 16 + inside / 25
            }
            score *= 1 + 0.03 * d  // the nearer of two equal patches wins
            if score < best.score { best = (score, dx, dy) }
        }
    }
    return (best.dx / w, best.dy / h)
}

// MARK: - Masks: local adjustments

enum MaskKind: String, Codable, CaseIterable { case brush, linear, radial }

/// A local adjustment (Masks tab). Positions are fractions of the photo's width and height and sizes fractions of its
/// shorter side, all before crop and rotation, so a mask lands in the same place at any size.
struct LocalMask: Codable, Equatable {
    var kind: MaskKind
    /// brush: dabs x, y, r, x, y, r, ... in painting order (a negative r erases); linear: x0, y0 (full effect), x1, y1
    /// (no effect); radial: cx, cy, rx, ry and optionally its angle in degrees, clockwise (the effect is inside)
    var shape: [Double]
    var feather: Double?  // 0...100, soft edge of brush dabs and radial masks (nil = 50)
    var invert: Bool?
    var exposure: Double?  // stops, -4...4
    var contrast: Double?, highlights: Double?, shadows: Double?, temp: Double?, tint: Double?  // -100...100; tint + is magenta
    var saturation: Double?, clarity: Double?, sharpness: Double?  // -100...100; negative sharpness softens
    var blur: Double?, blur_type: String?, blur_angle: Double?  // 0...100, a BlurKind (nil = lens), motion's direction

    var isValid: Bool { kind == .brush ? shape.count % 3 == 0 : kind == .radial ? (4...5).contains(shape.count) : shape.count == 4 }
    var angle: Double { kind == .radial && shape.count > 4 ? shape[4] : 0 }

    /// Where the mask is centred, as fractions of the photo: zoom blur streaks towards it.
    var center: (x: Double, y: Double) {
        switch kind {
        case .radial, .linear: return (shape[0], shape[1])
        case .brush:
            let dabs = stride(from: 0, to: shape.count - 2, by: 3).filter { shape[$0 + 2] > 0 }
            guard !dabs.isEmpty else { return (0.5, 0.5) }
            return (dabs.map { shape[$0] }.reduce(0, +) / Double(dabs.count), dabs.map { shape[$0 + 1] }.reduce(0, +) / Double(dabs.count))
        }
    }
}

/// How much of the mask's adjustment each pixel gets, 0...1.
func maskPlane(_ m: LocalMask, _ w: Int, _ h: Int) -> [Float] {
    let (W, H, side) = (Float(w), Float(h), Float(min(w, h))), f = max(0.01, Float((m.feather ?? 50) / 100)), s = m.shape.map { Float($0) }
    var out: [Float]
    switch m.kind {
    case .linear:
        let x0 = s[0] * W, y0 = s[1] * H, dx = (s[2] - s[0]) * W, dy = (s[3] - s[1]) * H, len2 = max(dx * dx + dy * dy, 1e-6)
        out = fill(w * h) { i in 1 - smoothstep(0, 1, ((Float(i % w) + 0.5 - x0) * dx + (Float(i / w) + 0.5 - y0) * dy) / len2) }
    case .radial:
        let cx = s[0] * W, cy = s[1] * H, rx = max(1, s[2] * side), ry = max(1, s[3] * side)
        let a = Float(m.angle * .pi / 180), (ca, sa) = (cosf(a), sinf(a))
        out = fill(w * h) { i in
            let X = Float(i % w) + 0.5 - cx, Y = Float(i / w) + 0.5 - cy
            let dx = (X * ca + Y * sa) / rx, dy = (Y * ca - X * sa) / ry  // in the ellipse's own (turned) axes
            return 1 - smoothstep(1 - f, 1, (dx * dx + dy * dy).squareRoot())
        }
    case .brush:
        out = [Float](repeating: 0, count: w * h)
        for k in stride(from: 0, to: s.count - 2, by: 3) {
            let cx = s[k] * W, cy = s[k + 1] * H, r = max(0.5, abs(s[k + 2]) * side), erase = s[k + 2] < 0
            for y in stride(from: max(0, Int(cy - r)), through: min(h - 1, Int(cy + r)), by: 1) {
                for x in stride(from: max(0, Int(cx - r)), through: min(w - 1, Int(cx + r)), by: 1) {
                    let v = 1 - smoothstep(1 - f, 1, hypot(Float(x) + 0.5 - cx, Float(y) + 0.5 - cy) / r)
                    out[y * w + x] = erase ? max(0, out[y * w + x] - v) : max(out[y * w + x], v)
                }
            }
        }
    }
    return m.invert == true ? out.map { 1 - $0 } : out
}

/// Each mask's settings applied to the picture so far, blended in through the mask (in order, like Lightroom's list).
func localMasks(_ x0: RGB, _ p: Params, _ s: Double) -> RGB {
    var x = x0
    for m in p.masks ?? [] where m.isValid {
        var q = Params()
        (q.exposure, q.contrast, q.highlights, q.shadows) = (m.exposure, m.contrast, m.highlights, m.shadows)
        (q.saturation, q.clarity_all, q.sharpen) = (m.saturation, m.clarity, m.sharpness.map { max(0, $0) })
        let temp = Float((m.temp ?? 0) / 100), tint = Float((m.tint ?? 0) / 100), soft = Float(-min(0, m.sharpness ?? 0) / 100)
        let blur = m.blur ?? 0
        if q.look == Params() && temp == 0 && tint == 0 && soft == 0 && blur <= 0 { continue }
        var y = sharpen(presence(light(x, q, s), q, s), q, s)
        if temp != 0 || tint != 0 {  // white balance in linear light, like the flash look's
            y = y.map { _, r, g, b in (srgb(lin(r) * (1 + 0.3 * temp)), srgb(lin(g) * (1 - 0.25 * tint)), srgb(lin(b) * (1 - 0.3 * temp))) }
        }
        if soft > 0 {
            let br = gauss(y.r, y.w, y.h, 2 * s), bg = gauss(y.g, y.w, y.h, 2 * s), bb = gauss(y.b, y.w, y.h, 2 * s)
            y = y.map { i, r, g, b in (r + (br[i] - r) * soft, g + (bg[i] - g) * soft, b + (bb[i] - b) * soft) }
        }
        if blur > 0 {  // the same blurs as the background's, everywhere the mask reaches
            var b = Params()
            (b.blur, b.blur_type, b.blur_angle) = (blur, m.blur_type, m.blur_angle)
            let c = m.center
            y = backgroundBlur(y, [Float](repeating: 0, count: y.n), b, s, center: (c.x * Double(y.w), c.y * Double(y.h)))
        }
        x = x.blend(y, maskPlane(m, x.w, x.h))
    }
    return x
}

// MARK: - Geometry: flip, quarter turns, straighten, crop

/// Where `geometry` takes each output pixel from, and back: output pixels <-> photo pixels.
/// Output pixel -> straightened frame -> turned-and-flipped frame -> original photo.
struct Geo {
    let sw: Float, sh: Float, W: Float, H: Float, quarter: Int, flip: Bool, k: Float, ct: Float, st: Float
    let ox: Float, oy: Float, ow: Int, oh: Int, isIdentity: Bool

    init(_ p: Params, _ w: Int, _ h: Int, crop useCrop: Bool = true) {
        quarter = ((Int(((p.rotate ?? 0) / 90).rounded()) % 4) + 4) % 4; flip = (p.flip ?? 0) != 0
        let theta = Float((p.straighten ?? 0) * .pi / 180), c = useCrop ? (p.crop ?? [0, 0, 1, 1]) : [0, 0, 1, 1]
        isIdentity = quarter == 0 && !flip && theta == 0 && c == [0, 0, 1, 1]
        (sw, sh) = (Float(w), Float(h))
        (W, H) = quarter % 2 == 0 ? (sw, sh) : (sh, sw)
        let cs = cosf(abs(theta)), sn = sinf(abs(theta))
        k = max((W * cs + H * sn) / W, (W * sn + H * cs) / H)  // straightening scales up so no empty corners show
        ow = max(1, Int((c[2] * Double(W)).rounded())); oh = max(1, Int((c[3] * Double(H)).rounded()))
        ox = Float(c[0]) * W; oy = Float(c[1]) * H; (ct, st) = (cosf(theta), sinf(theta))
    }

    /// Output position (px) -> photo position (px).
    func source(_ x: Float, _ y: Float) -> (Float, Float) {
        let X = ox + x - W / 2, Y = oy + y - H / 2
        var fx = (X * ct + Y * st) / k + W / 2, fy = (-X * st + Y * ct) / k + H / 2
        if flip { fx = W - fx }
        switch quarter {
        case 1: return (fy, sh - fx)
        case 2: return (sw - fx, sh - fy)
        case 3: return (sw - fy, fx)
        default: return (fx, fy)
        }
    }

    /// Photo position (px) -> output position (px): `source` run backwards.
    func output(_ px: Float, _ py: Float) -> (Float, Float) {
        var (fx, fy): (Float, Float)
        switch quarter {
        case 1: (fx, fy) = (sh - py, px)
        case 2: (fx, fy) = (sw - px, sh - py)
        case 3: (fx, fy) = (py, sw - px)
        default: (fx, fy) = (px, py)
        }
        if flip { fx = W - fx }
        let u = (fx - W / 2) * k, v = (fy - H / 2) * k
        return (u * ct - v * st + W / 2 - ox, u * st + v * ct + H / 2 - oy)
    }
}

/// Applied after the edit, to before and after alike. Straightening scales up just enough that no empty corners show.
/// `crop: false` shows the whole straightened frame (for editing the crop box).
func geometry(_ x: RGB, _ p: Params, crop useCrop: Bool = true) -> RGB {
    let g = Geo(p, x.w, x.h, crop: useCrop), (ow, oh) = (g.ow, g.oh)
    if g.isIdentity { return x }
    func sample(_ ch: [Float], _ px: Float, _ py: Float) -> Float {
        let fx = min(max(px - 0.5, 0), g.sw - 1), fy = min(max(py - 0.5, 0), g.sh - 1)
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, x.w - 1), y1 = min(y0 + 1, x.h - 1), tx = fx - Float(x0), ty = fy - Float(y0)
        let a = ch[y0 * x.w + x0] + (ch[y0 * x.w + x1] - ch[y0 * x.w + x0]) * tx, b = ch[y1 * x.w + x0] + (ch[y1 * x.w + x1] - ch[y1 * x.w + x0]) * tx
        return a + (b - a) * ty
    }
    let src = fill(ow * oh) { g.source(Float($0 % ow) + 0.5, Float($0 / ow) + 0.5).0 }
    let srcY = fill(ow * oh) { g.source(Float($0 % ow) + 0.5, Float($0 / ow) + 0.5).1 }
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
