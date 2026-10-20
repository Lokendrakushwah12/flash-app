// Swift port of reference/flashgrade.py `edit()` (the source of truth), plus flashmask.swift's Vision step.
// Images are planar Float32 in [0,1]. Filters reproduce scipy.ndimage exactly: gaussian_filter (truncate=4),
// uniform_filter and minimum_filter all with mode='reflect', distance_transform_edt, and scipy's PchipInterpolator.
import Accelerate
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Parameters (same keys as preset*.json)

struct Params: Codable, Equatable {
    var omega = 0.0, temp_ambient = 0.0, tint_ambient = 0.0, temp_flash = 0.0, tint_flash = 0.0
    var sat_ambient = 1.0, sat_flash = 1.0, spill = 0.0, shine = 0.0, clarity = 0.0
    var ambient = [Double](repeating: 0.125, count: 8), flash = [Double](repeating: 0.125, count: 8)
    var skin_L = 0.0, skin_a = 0.0, skin_b = 0.0, white = 0.0, warm_ev = 0.0, skin_contrast = 1.0
    var body_L: Double?  // nil = same as skin_L, like p.get("body_L", p["skin_L"])
    var fog = 0.0, fog_start = 0.3, fog_gamma = 1.0, fog_color = [0.6, 0.65, 0.62]
    // App-only knobs (not in flashgrade.py). Optional so catalogs saved before they existed still load.
    var strength: Double?  // how much of the look is applied, 0...1 (nil = 1)
    var plastic: Double?  // plastic shine on visible skin, -100...100 (nil = 0; negative = matte)
    var lips: Double?  // pink lips, -100...100 (nil = 0; negative = nude)
    // Color Mixer, like Lightroom's HSL: 8 bands (red, orange, yellow, green, aqua, blue, purple, magenta), -100...100
    var hsl_hue: [Double]?, hsl_sat: [Double]?, hsl_lum: [Double]?
    // Lightroom-style develop (Develop.swift). Sliders are -100...100 unless noted.
    var exposure: Double?  // stops, -5...5
    var contrast: Double?, highlights: Double?, shadows: Double?, whites: Double?, blacks: Double?
    var texture: Double?, clarity_all: Double?, vibrance: Double?, saturation: Double?
    var curve: [Double]?, curve_r: [Double]?, curve_g: [Double]?, curve_b: [Double]?  // tone-curve points x0,y0,x1,y1,... in 0...1
    var grade_shadows: [Double]?, grade_midtones: [Double]?, grade_highlights: [Double]?  // [hue 0...360, saturation 0...100, luminance]
    var grade_balance: Double?
    var sharpen: Double?, sharpen_radius: Double?, sharpen_masking: Double?  // amount 0...150, radius 0.5...3 px, masking 0...100
    var denoise: Double?, denoise_color: Double?  // 0...100
    var vignette: Double?, vignette_midpoint: Double?, vignette_feather: Double?, vignette_roundness: Double?
    var grain: Double?, grain_size: Double?  // 0...100
    var blur: Double?, blur_type: String?, blur_angle: Double?, blur_focus: Double?, blur_bokeh: Double?  // background blur
    var crop: [Double]?, straighten: Double?, rotate: Double?, flip: Double?  // geometry: [x, y, w, h] in 0...1, degrees, 0/90/180/270, 1 = mirrored
    var heal: [[Double]]?  // spot removal: [x, y, r, sx, sy] per spot (Develop.swift `heal`)
    var masks: [LocalMask]?  // local adjustments: brush, linear and radial masks, each with its own settings

    /// Optional knobs where 0 means off.
    static let zeroIsOff: [WritableKeyPath<Params, Double?>] = [\.plastic, \.lips, \.exposure, \.contrast, \.highlights, \.shadows,
        \.whites, \.blacks, \.texture, \.clarity_all, \.vibrance, \.saturation, \.grade_balance, \.sharpen, \.denoise, \.denoise_color,
        \.vignette, \.grain, \.blur]
    /// Keys the app adds on top of flashgrade.py's look.
    static let appKeys = ["strength", "plastic", "lips", "hsl_hue", "hsl_sat", "hsl_lum", "exposure", "contrast", "highlights", "shadows",
        "whites", "blacks", "texture", "clarity_all", "vibrance", "saturation", "curve", "curve_r", "curve_g", "curve_b", "grade_shadows",
        "grade_midtones", "grade_highlights", "grade_balance", "sharpen", "sharpen_radius", "sharpen_masking", "denoise", "denoise_color",
        "vignette", "vignette_midpoint", "vignette_feather", "vignette_roundness", "grain", "grain_size", "blur", "blur_type", "blur_angle",
        "blur_focus", "blur_bokeh", "crop", "straighten", "rotate", "flip", "heal", "masks"]

    /// The edit at full strength with every "off" knob as nil. Geometry is left out: it's applied after the edit.
    var look: Params {
        var q = self
        q.strength = nil
        for kp in Params.zeroIsOff where q[keyPath: kp] == 0 { q[keyPath: kp] = nil }
        for kp in [\Params.hsl_hue, \.hsl_sat, \.hsl_lum] where q[keyPath: kp]?.allSatisfy({ $0 == 0 }) == true { q[keyPath: kp] = nil }
        for kp in [\Params.curve, \.curve_r, \.curve_g, \.curve_b] where q[keyPath: kp] == [0, 0, 1, 1] { q[keyPath: kp] = nil }
        for kp in [\Params.grade_shadows, \.grade_midtones, \.grade_highlights] where q[keyPath: kp].map({ $0.count == 3 && $0[1] == 0 && $0[2] == 0 }) == true {
            q[keyPath: kp] = nil
        }
        if q.grade_shadows == nil && q.grade_midtones == nil && q.grade_highlights == nil { q.grade_balance = nil }
        if q.blur == nil { (q.blur_type, q.blur_angle, q.blur_focus, q.blur_bokeh) = (nil, nil, nil, nil) }
        if q.vignette == nil { (q.vignette_midpoint, q.vignette_feather, q.vignette_roundness) = (nil, nil, nil) }
        if q.grain == nil { q.grain_size = nil }
        if q.sharpen == nil { (q.sharpen_radius, q.sharpen_masking) = (nil, nil) }
        if q.heal?.isEmpty == true { q.heal = nil }
        if q.masks?.isEmpty == true { q.masks = nil }
        (q.crop, q.straighten, q.rotate, q.flip) = (nil, nil, nil, nil)
        return q
    }

    /// Only the flash look (flashgrade.py's keys); everything the app adds is dropped.
    var flashLook: Params {
        var d = dict
        for k in Params.appKeys { d.removeValue(forKey: k) }
        return try! JSONDecoder().decode(Params.self, from: JSONSerialization.data(withJSONObject: d))
    }

    /// The photo's own edits (crop and rotation, heal spots, masks): a new preset keeps them.
    mutating func keepLocal(from o: Params) {
        (crop, straighten, rotate, flip, heal, masks) = (o.crop, o.straighten, o.rotate, o.flip, o.heal, o.masks)
    }

    var hasGeometry: Bool { (straighten ?? 0) != 0 || (rotate ?? 0) != 0 || (flip ?? 0) != 0 || (crop != nil && crop! != [0, 0, 1, 1]) }

    /// Keys missing from `json` keep their current value, so presets, saved edits and Claude's partial
    /// updates all go through here. Rejects wrong-length arrays, since the curves need exactly 8 steps.
    func merged(_ json: [String: Any]) throws -> Params {
        var d = dict
        d.merge(json) { $1 }
        let p = try JSONDecoder().decode(Params.self, from: JSONSerialization.data(withJSONObject: d))
        guard p.ambient.count == 8, p.flash.count == 8, p.fog_color.count == 3,
              [p.hsl_hue, p.hsl_sat, p.hsl_lum].allSatisfy({ $0 == nil || $0!.count == 8 }),
              [p.curve, p.curve_r, p.curve_g, p.curve_b].allSatisfy({ $0 == nil || ($0!.count >= 4 && $0!.count % 2 == 0) }),
              [p.grade_shadows, p.grade_midtones, p.grade_highlights].allSatisfy({ $0 == nil || $0!.count == 3 }),
              p.crop == nil || p.crop!.count == 4, (p.heal ?? []).allSatisfy({ $0.count == 5 }), (p.masks ?? []).allSatisfy(\.isValid) else {
            throw NSError(domain: "FlashEdit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "ambient/flash need 8 values, fog_color 3, hsl_* 8, curves x,y pairs, grade_* [hue, sat, lum], crop [x, y, w, h], " +
                "heal spots [x, y, r, sx, sy], mask shapes: linear and radial 4 numbers, brush x, y, r triples"])
        }
        return p
    }

    static let presetInfo = ["none: the original photo, build a look with the sliders or chat", "golden hour: vivid background, warm flash, bright skin", "sunny haze: dehazed, warm, light fog",
                             "overcast: neutral, darker hair and body skin", "misty forest: cool, heavy fog, flash spill"]

    static func preset(_ k: Int) -> Params { k == 0 ? Params() : presets[k - 1] }  // 0 = None: neutral, leaves the photo untouched

    private static let presets = (1...4).map { k in
        // FlashEdit.app: Contents/Resources (build.sh copies them there); swift run / Xcode: the SwiftPM resource bundle
        let url = Bundle.main.url(forResource: "preset\(k)", withExtension: "json")
            ?? Bundle.module.url(forResource: "preset\(k)", withExtension: "json", subdirectory: "Presets")!
        return try! Params().merged(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])
    }

    var dict: [String: Any] { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any] }

    /// Replays the change old -> new on top of self: numbers and arrays shift by the same amount, anything else is copied.
    /// Keeps isolated background/person edits in step with whole-photo edits.
    func carrying(from old: Params, to new: Params) -> Params {
        let o = old.dict
        var d = dict
        let nd = new.dict
        for k in o.keys where nd[k] == nil { d.removeValue(forKey: k) }  // switched off (nil) on the whole photo
        for (k, v) in nd where (o[k] as? NSObject) != (v as? NSObject) {
            if let a = v as? Double, let b = o[k] as? Double, let c = d[k] as? Double { d[k] = c + a - b }
            else if let a = v as? [Double], let b = o[k] as? [Double], let c = d[k] as? [Double], a.count == c.count, b.count == c.count {
                d[k] = (0..<c.count).map { c[$0] + a[$0] - b[$0] }
            } else { d[k] = v }
        }
        return (try? Params().merged(d)) ?? self
    }

    var json: String { String(data: try! JSONEncoder.sorted.encode(self), encoding: .utf8)! }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
}

struct Face: Codable, Equatable { var x, y, w, h: Int; var outerLips: [CGPoint] = [], innerLips: [CGPoint] = [] }  // top-left origin, px (as flashmask prints them)

// MARK: - Planar image and parallel helpers

func par(_ n: Int, grain: Int = 32768, _ body: (Range<Int>) -> Void) {
    let k = max(1, min(64, n / grain))
    DispatchQueue.concurrentPerform(iterations: k) { c in body(n * c / k ..< n * (c + 1) / k) }
}

func fill(_ n: Int, _ f: (Int) -> Float) -> [Float] {
    [Float](unsafeUninitializedCapacity: n) { buf, count in
        let p = buf.baseAddress!
        par(n) { for i in $0 { p[i] = f(i) } }
        count = n
    }
}

struct RGB {
    var w: Int, h: Int, r: [Float], g: [Float], b: [Float]
    var n: Int { w * h }
    var lumaPlane: [Float] { fill(n) { luma(r[$0], g[$0], b[$0]) } }
    func plane(_ f: (Int) -> Float) -> [Float] { fill(n, f) }
    func map(_ f: (Int, Float, Float, Float) -> (Float, Float, Float)) -> RGB {
        var R = [Float](repeating: 0, count: n), G = R, B = R
        R.withUnsafeMutableBufferPointer { R in G.withUnsafeMutableBufferPointer { G in B.withUnsafeMutableBufferPointer { B in
            let (pr, pg, pb) = (R.baseAddress!, G.baseAddress!, B.baseAddress!)
            par(n) { for i in $0 { (pr[i], pg[i], pb[i]) = f(i, r[i], g[i], b[i]) } }
        }}}
        return RGB(w: w, h: h, r: R, g: G, b: B)
    }
    func blend(_ o: RGB, _ t: [Float]) -> RGB { map { i, r, g, b in (r * (1 - t[i]) + o.r[i] * t[i], g * (1 - t[i]) + o.g[i] * t[i], b * (1 - t[i]) + o.b[i] * t[i]) } }
}

@inline(__always) func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
@inline(__always) func clip01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func lin(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((max(x, 0) + 0.055) / 1.055, 2.4) }
@inline(__always) func srgb(_ v: Float) -> Float { let x = clip01(v); return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055 }

// MARK: - scipy.ndimage filters

/// scipy 'reflect' border: d c b a | a b c d | d c b a
func reflect(_ i: Int, _ n: Int) -> Int { let m = ((i % (2 * n)) + 2 * n) % (2 * n); return m < n ? m : 2 * n - 1 - m }

func transpose(_ x: [Float], _ w: Int, _ h: Int) -> [Float] {  // h rows × w cols -> w rows × h cols
    var o = [Float](repeating: 0, count: w * h)
    vDSP_mtrans(x, 1, &o, 1, vDSP_Length(w), vDSP_Length(h))
    return o
}

/// Runs `op(paddedRow, outRow)` on every row, with rows padded by `pad` reflected pixels on each side.
func rowsOp(_ x: [Float], _ w: Int, _ h: Int, pad r: Int, _ op: (UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Void) -> [Float] {
    let idx = (-r..<w + r).map { reflect($0, w) }
    var out = [Float](repeating: 0, count: w * h)
    out.withUnsafeMutableBufferPointer { o in
        let po = o.baseAddress!
        par(h, grain: 8) { rows in
            var row = [Float](repeating: 0, count: w + 2 * r)
            for y in rows {
                for j in row.indices { row[j] = x[y * w + idx[j]] }
                row.withUnsafeBufferPointer { op($0.baseAddress!, po + y * w) }
            }
        }
    }
    return out
}

/// Same 1-D op along rows then columns.
func separable(_ x: [Float], _ w: Int, _ h: Int, pad: Int, _ op: (UnsafePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) -> [Float] {
    let a = rowsOp(x, w, h, pad: pad) { op($0, $1, w) }
    let b = rowsOp(transpose(a, w, h), h, w, pad: pad) { op($0, $1, h) }
    return transpose(b, h, w)
}

func correlate(_ x: [Float], _ w: Int, _ h: Int, _ k: [Float]) -> [Float] {
    separable(x, w, h, pad: k.count / 2) { vDSP_conv($0, 1, k, 1, $1, 1, vDSP_Length($2), vDSP_Length(k.count)) }
}

/// scipy.ndimage.gaussian_filter(x, sigma)
func gauss(_ x: [Float], _ w: Int, _ h: Int, _ sigma: Double) -> [Float] {
    let r = Int(4 * sigma + 0.5)
    if r == 0 { return x }
    let k = (-r...r).map { exp(-0.5 / (sigma * sigma) * Double($0 * $0)) }, s = k.reduce(0, +)
    return correlate(x, w, h, k.map { Float($0 / s) })
}

/// scipy.ndimage.uniform_filter(x, size)
func box(_ x: [Float], _ w: Int, _ h: Int, _ size: Int) -> [Float] { correlate(x, w, h, [Float](repeating: 1 / Float(size), count: size)) }

/// scipy.ndimage.minimum_filter(x, size), as -max(-x) over sliding windows
func minFilter(_ x: [Float], _ w: Int, _ h: Int, _ size: Int) -> [Float] {
    separable(x, w, h, pad: size / 2) { src, dst, n in
        var neg = [Float](repeating: 0, count: n + size - 1)
        vDSP_vneg(src, 1, &neg, 1, vDSP_Length(neg.count))
        vDSP_vswmax(neg, 1, dst, 1, vDSP_Length(n), vDSP_Length(size))
        vDSP_vneg(dst, 1, dst, 1, vDSP_Length(n))
    }
}

/// scipy.ndimage.distance_transform_edt(~feature): exact Euclidean distance to the nearest feature pixel
/// (Felzenszwalb & Huttenlocher, columns then rows).
func edt(_ feature: [Bool], _ w: Int, _ h: Int) -> [Float] {
    var d = feature.map { $0 ? 0.0 : 1e20 }
    d.withUnsafeMutableBufferPointer { b in
        let p = b.baseAddress!
        par(w, grain: 8) { for x in $0 { dt1(p + x, h, w) } }
        par(h, grain: 8) { for y in $0 { dt1(p + y * w, w, 1) } }
    }
    return d.map { Float($0.squareRoot()) }
}

private func dt1(_ p: UnsafeMutablePointer<Double>, _ n: Int, _ st: Int) {
    let f = (0..<n).map { p[$0 * st] }
    var v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1), k = 0
    z[0] = -.infinity; z[1] = .infinity
    for q in 1..<max(n, 1) {
        var s = 0.0
        while true {
            let vk = v[k]
            s = ((f[q] - f[vk]) + Double(q * q - vk * vk)) / Double(2 * (q - vk))
            if s > z[k] { break }
            k -= 1
        }
        k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
    }
    k = 0
    for q in 0..<n {
        while z[k + 1] < Double(q) { k += 1 }
        let dq = Double(q - v[k]); p[q * st] = dq * dq + f[v[k]]
    }
}

// MARK: - Tone curve: scipy PchipInterpolator through 9 knots at x = k/8

struct Curve {
    private var y = [Double](), d = [Double](repeating: 0, count: 9), m = [Double]()
    private let h = 1.0 / 8

    init(_ steps: [Double]) {
        var acc = 0.0
        y = [0] + steps.map { acc += max($0, 0); return acc }
        y = y.map { min($0, 1) }
        m = (0..<8).map { (y[$0 + 1] - y[$0]) / h }
        func sgn(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }
        for k in 1..<8 where !(sgn(m[k]) != sgn(m[k - 1]) || m[k] == 0 || m[k - 1] == 0) {
            let w1 = 3 * h, w2 = 3 * h  // 2h_k + h_{k-1}, h_k + 2h_{k-1}
            d[k] = 1 / ((w1 / m[k - 1] + w2 / m[k]) / (w1 + w2))
        }
        func edge(_ m0: Double, _ m1: Double) -> Double {
            let e = ((2 * h + h) * m0 - h * m1) / (h + h)
            if sgn(e) != sgn(m0) { return 0 }
            if sgn(m0) != sgn(m1) && abs(e) > 3 * abs(m0) { return 3 * m0 }
            return e
        }
        d[0] = edge(m[0], m[1]); d[8] = edge(m[7], m[6])
    }

    func callAsFunction(_ v: Float) -> Float {
        let x = Double(clip01(v)), k = min(Int(x * 8), 7), t = x - Double(k) * h
        let c3 = (d[k] + d[k + 1] - 2 * m[k]) / h
        return Float(((c3 / h * t + ((m[k] - d[k]) / h - c3)) * t + d[k]) * t + y[k])
    }
}

// MARK: - Color

private let MI: [Float] = [3.24062548, -1.53720797, -0.4986286, -0.96893071, 1.87575606, 0.04151752, 0.05571012, -0.20402105, 1.05699594]  // np.linalg.inv(XYZ)

@inline(__always) func rgb2lab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let R = lin(r), G = lin(g), B = lin(b)
    @inline(__always) func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(max(t, 0)) : 7.787 * t + 16 / 116 }
    let fx = f((0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.9505), fy = f(0.2126 * R + 0.7152 * G + 0.0722 * B)
    let fz = f((0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.089)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

@inline(__always) func lab2rgb(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
    @inline(__always) func g(_ t: Float) -> Float { t > 0.2069 ? t * t * t : (t - 16 / 116) / 7.787 }
    let fy = (L + 16) / 116, X = g(fy + a / 500) * 0.9505, Y = g(fy), Z = g(fy - b / 200) * 1.089
    return (srgb(MI[0] * X + MI[1] * Y + MI[2] * Z), srgb(MI[3] * X + MI[4] * Y + MI[5] * Z), srgb(MI[6] * X + MI[7] * Y + MI[8] * Z))
}

func labShift(_ x: RGB, _ dL: Float, _ da: Float, _ db: Float) -> RGB {
    x.map { _, r, g, b in let (L, A, B) = rgb2lab(r, g, b); return lab2rgb(L + dL, A + da, B + db) }
}

// MARK: - Pipeline (one function per Python function)

func guided(_ I: [Float], _ p: [Float], _ r: Int, _ eps: Float, _ w: Int, _ h: Int) -> [Float] {
    let bx = { gauss($0, w, h, Double(r) / 2) }  // round windows: square ones leave blocky patches in the mask
    let n = w * h, mI = bx(I), mp = bx(p), mIp = bx(fill(n) { I[$0] * p[$0] }), mII = bx(fill(n) { I[$0] * I[$0] })
    let a = fill(n) { (mIp[$0] - mI[$0] * mp[$0]) / (mII[$0] - mI[$0] * mI[$0] + eps) }
    let b = fill(n) { mp[$0] - a[$0] * mI[$0] }
    let ma = bx(a), mb = bx(b)
    return fill(n) { ma[$0] * I[$0] + mb[$0] }
}

func dehaze(_ img: RGB, _ omega: Double, _ s: Double) -> RGB {
    let (w, h, n) = (img.w, img.h, img.n), patch = max(3, Int(15 * s) | 1)
    let dark = minFilter(img.plane { min(img.r[$0], img.g[$0], img.b[$0]) }, w, h, patch)
    // airlight = mean colour of the brightest 0.1% of the dark channel; ties at the cut go to the
    // highest indices, like a stable argsort
    let k = max(1, n / 1000)
    var sorted = dark; vDSP_vsort(&sorted, vDSP_Length(n), -1)
    let cut = sorted[k - 1]
    var need = k - dark.reduce(0) { $0 + ($1 > cut ? 1 : 0) }, A = [Double](repeating: 0, count: 3)
    for i in stride(from: n - 1, through: 0, by: -1) where dark[i] > cut || (dark[i] == cut && need > 0) {
        if dark[i] == cut { need -= 1 }
        A[0] += Double(img.r[i]); A[1] += Double(img.g[i]); A[2] += Double(img.b[i])
    }
    let (a0, a1, a2) = (Float(A[0] / Double(k)), Float(A[1] / Double(k)), Float(A[2] / Double(k)))
    let om = Float(omega)
    let t0 = minFilter(img.plane { min(img.r[$0] / a0, img.g[$0] / a1, img.b[$0] / a2) }, w, h, patch).map { 1 - om * $0 }
    let t = guided(img.lumaPlane, t0, max(4, Int(40 * s)), 1e-3, w, h)
    return img.map { i, r, g, b in let tt = max(t[i], 0.1); return ((r - a0) / tt + a0, (g - a1) / tt + a1, (b - a2) / tt + a2) }
}

func tone(_ x: RGB, _ steps: [Double], _ sat: Double, _ temp: Double, _ tint: Double) -> RGB {
    let c = Curve(steps), s = Float(sat), wr = Float(1 + temp), wg = Float(1 + tint), wb = Float(1 - temp)
    return x.map { _, r, g, b in
        let y = max(luma(r, g, b), 1e-4), k = c(y) / y
        let R = srgb(lin(clip01(r * k)) * wr), G = srgb(lin(clip01(g * k)) * wg), B = srgb(lin(clip01(b * k)) * wb)
        let y2 = luma(R, G, B)
        return (y2 + (R - y2) * s, y2 + (G - y2) * s, y2 + (B - y2) * s)
    }
}

func skinWeight(_ img: RGB) -> [Float] {
    img.plane { i in
        let r = img.r[i], g = img.g[i], b = img.b[i], y = luma(r, g, b)
        let warm = clip01((r - b - 0.02) / 0.06) * clip01((r - g + 0.01) / 0.03)
        return warm * clip01((y - 0.12) / 0.08) * clip01((0.95 - y) / 0.1)
    }
}

func faceMask(_ w: Int, _ h: Int, _ f: Face, _ person: [Float]) -> [Float] {
    let cx = Float(f.x) + Float(f.w) / 2, cy = Float(f.y) + Float(f.h) * 0.55, ax = Float(f.w) * 0.85, ay = Float(f.h) * 0.85
    return fill(w * h) { i in
        let dx = (Float(i % w) - cx) / ax, dy = (Float(i / w) - cy) / ay
        return clip01((1.25 - (dx * dx + dy * dy)) / 0.5) * clip01(person[i] * 1.5)
    }
}

func skinSmooth(_ img: RGB, _ r: Int, _ eps: Float = 0.002) -> RGB {
    let (w, h, n) = (img.w, img.h, img.n)
    func ch(_ I: [Float]) -> [Float] {
        let m = box(I, w, h, 2 * r + 1), m2 = box(fill(n) { I[$0] * I[$0] }, w, h, 2 * r + 1)
        let a = fill(n) { let v = m2[$0] - m[$0] * m[$0]; return v / (v + eps) }
        let ma = box(a, w, h, 2 * r + 1), mb = box(fill(n) { m[$0] - a[$0] * m[$0] }, w, h, 2 * r + 1)
        return fill(n) { ma[$0] * I[$0] + mb[$0] }
    }
    return RGB(w: w, h: h, r: ch(img.r), g: ch(img.g), b: ch(img.b))
}

func flashLight(_ x0: RGB, _ p: Params, _ s: Double) -> RGB {
    var x = tone(x0, p.flash, p.sat_flash, p.temp_flash, p.tint_flash)
    if p.warm_ev != 0 {  // luminance of dark warm tones (brown hair), like Lightroom's orange-luminance slider
        let w0 = x.plane { i in clip01((x.r[i] - x.b[i] - 0.02) / 0.06) * clip01((0.5 - luma(x.r[i], x.g[i], x.b[i])) / 0.15) }
        let w = gauss(w0, x.w, x.h, 2 * s), ev = Float(p.warm_ev)
        x = x.map { i, r, g, b in let e = exp2f(ev * w[i]); return (srgb(lin(r) * e), srgb(lin(g) * e), srgb(lin(b) * e)) }
    }
    let hi = x.plane { powf(clip01((luma(x.r[$0], x.g[$0], x.b[$0]) - 0.45) / 0.4), 1.5) }
    let shine = Float(p.shine), white = Float(p.white)
    x = x.map { i, r, g, b in
        let R = r + shine * hi[i] * (1 - r), G = g + shine * hi[i] * (1 - g), B = b + shine * hi[i] * (1 - b)
        let y = luma(R, G, B), k = 1 - white * hi[i]  // flash keeps whites neutral
        return (y + (R - y) * k, y + (G - y) * k, y + (B - y) * k)
    }
    let cl = Float(p.clarity), sg = 3 * s
    let br = gauss(x.r, x.w, x.h, sg), bg = gauss(x.g, x.w, x.h, sg), bb = gauss(x.b, x.w, x.h, sg)
    return x.map { i, r, g, b in let k = cl * (0.3 + hi[i]); return (r + k * (r - br[i]), g + k * (g - bg[i]), b + k * (b - bb[i])) }
}

/// refine_mask: snap the coarse Vision mask to real edges (cap against sky, hair) with a guided filter.
func personMask(_ img: RGB, _ M: [Float]) -> [Float] {
    guided(img.lumaPlane, M, max(4, Int(8 * Double(min(img.w, img.h)) / 720)), 1e-3, img.w, img.h).map(clip01)
}

/// Isolate: background and person can carry different edits, blended along the refined person mask.
func edit(_ img: RGB, _ M: [Float], _ faces: [Face], bg: Params, fg: Params) -> RGB {
    if bg == fg { return edit(img, M, faces, bg) }
    return edit(img, M, faces, bg).blend(edit(img, M, faces, fg), personMask(img, M))
}

/// The whole edit: the flash look (only when one is set), then the Lightroom-style develop stages (Develop.swift).
/// Crop and straighten come after this, in `geometry`.
func edit(_ img0: RGB, _ M: [Float], _ faces: [Face], _ p: Params) -> RGB {
    if let spots = p.heal { var q = p; q.heal = nil; return edit(heal(img0, spots), M, faces, q) }  // first, so Strength never fades it
    if p.look == Params() || p.strength ?? 1 <= 0 { return img0 }  // preset None: the photo as shot (skips even the face smoothing)
    if let k = p.strength, k < 1 {  // Strength: fade between the photo and the full edit
        let e = edit(img0, M, faces, p.look), t = Float(k)
        return img0.map { i, r, g, b in (r + (e.r[i] - r) * t, g + (e.g[i] - g) * t, b + (e.b[i] - b) * t) }
    }
    let s = Double(min(img0.h, img0.w)) / 720  // parameters were fitted on ~720px photos
    let img = denoise(img0, p, s)  // Detail > Noise reduction works on the photo itself (no-op when off)
    let Mr = personMask(img, M)
    let x = p.flashLook == Params() ? img : flashGrade(img, faces, p, Mr, s)
    return develop(x, img, Mr, faces, p, s)
}

/// Ambient exposure on the background, flash exposure on the person (like a real flash shot): flashgrade.py's `edit()`.
func flashGrade(_ img: RGB, _ faces: [Face], _ p: Params, _ Mr: [Float], _ s: Double) -> RGB {
    let (W, H, n) = (img.w, img.h, img.n)
    var x = dehaze(img, p.omega, s).map { _, r, g, b in (clip01(r), clip01(g), clip01(b)) }
    // a real flash also reaches the scene just behind the person, so the edge fades instead of looking cut out
    let dist = edt(Mr.map { $0 >= 0.5 }, W, H), sp = Float(p.spill), fall = Float(60 * s)
    let Wf = fill(n) { Mr[$0] + (1 - Mr[$0]) * sp * expf(-dist[$0] / fall) }
    let amb = tone(x, p.ambient, p.sat_ambient, p.temp_ambient, p.tint_ambient), fl = flashLight(x, p, s)
    x = amb.blend(fl, Wf).map { _, r, g, b in (clip01(r), clip01(g), clip01(b)) }
    if p.fog > 0 {  // mist behind the person, thicker toward the top (farther away)
        let fs = Float(p.fog_start), fg = Float(p.fog_gamma), fo = Float(p.fog)
        let ramp = (0..<H).map { y -> Float in powf(clip01((1 - Float(y) / Float(H - 1) - fs) / (1 - fs + 1e-6)), fg) }
        let c = p.fog_color.map(Float.init)
        x = x.map { i, r, g, b in
            let f = fo * ramp[i / W] * (1 - Mr[i])
            return (r * (1 - f) + c[0] * f, g * (1 - f) + c[1] * f, b * (1 - f) + c[2] * f)
        }
    }
    // hands, neck, arms: same skin tone as the face (skin-coloured and brighter than hair)
    let sw = skinWeight(img)
    let body0 = img.plane { i in sw[i] * clip01((img.r[i] - img.b[i] - 0.11) / 0.04) * clip01((luma(img.r[i], img.g[i], img.b[i]) - 0.33) / 0.08) }
    var body = gauss(body0, W, H, s)
    let fmasks = faces.map { faceMask(W, H, $0, Mr) }
    body = fill(n) { i in fmasks.reduce(body[i] * Mr[i]) { $0 * (1 - $1[i]) } }
    if !faces.isEmpty {
        x = x.blend(labShift(x, Float(p.body_L ?? p.skin_L), Float(p.skin_a), Float(p.skin_b)), body)
    }
    let swb = gauss(sw, W, H, 1.5 * s)
    for (f, fm) in zip(faces, fmasks) {
        let F = fill(n) { fm[$0] * swb[$0] }
        var lab = x.map { _, r, g, b in rgb2lab(r, g, b) }  // r,g,b planes hold L,a,b here
        if p.skin_contrast != 1 {  // keep the face's own shading (cheek/jaw shadows), scaled by skin_contrast
            let Lm = gauss(lab.r, W, H, Double(f.w) / 4), c = Float(p.skin_contrast)
            lab.r = fill(n) { Lm[$0] + (lab.r[$0] - Lm[$0]) * c }
        }
        let (dL, da, db) = (Float(p.skin_L), Float(p.skin_a), Float(p.skin_b))
        let shifted = lab.map { _, L, a, b in lab2rgb(L + dL, a + da, b + db) }
        x = x.blend(skinSmooth(shifted, max(2, Int((Double(f.w) / 35).rounded(.toNearestOrEven)))), F)
    }
    return x.map { _, r, g, b in (clip01(r), clip01(g), clip01(b)) }
}

/// Plastic shine on visible skin. t > 0: waxy, glossy skin (texture smoothed away, soft sheen on the skin's
/// highlights). t < 0: matte (shiny spots pulled to the skin tone around them).
func plasticSkin(_ x: RGB, _ skin: [Float], _ t: Float, _ s: Double) -> RGB {
    let (w, h, n) = (x.w, x.h, x.n), y = x.lumaPlane
    // the skin colour around each pixel, averaged over skin only, so hair, shadows and background don't count
    let ws = gauss(skin, w, h, 8 * s)
    let avg = [x.r, x.g, x.b].map { c in
        let m = gauss(fill(n) { c[$0] * skin[$0] }, w, h, 8 * s)
        return fill(n) { m[$0] / max(ws[$0], 1e-3) }
    }
    // shiny peaks: clearly brighter than the skin around them (forehead, nose bridge, cheekbones), not just bright
    let spec = fill(n) { i in skin[i] * clip01((y[i] - luma(avg[0][i], avg[1][i], avg[2][i])) / 0.1) * clip01((y[i] - 0.3) / 0.3) }
    if t > 0 {
        let sm = skinSmooth(x, max(2, Int((3 * s).rounded())), 0.01), glow = gauss(spec, w, h, 1.5 * s)
        return x.map { i, r, g, b in
            let k = skin[i] * t, gl = min(1, glow[i] * t * 0.5)
            let R = r + (sm.r[i] - r) * k, G = g + (sm.g[i] - g) * k, B = b + (sm.b[i] - b) * k
            return (R + gl * (1 - R), G + gl * (1 - G), B + gl * (1 - B))
        }
    }
    return x.map { i, r, g, b in
        let k = spec[i] * -t * 0.8
        return (r + (avg[0][i] - r) * k, g + (avg[1][i] - g) * k, b + (avg[2][i] - b) * k)
    }
}

/// HSV hues of the Color Mixer bands: red, orange, yellow, green, aqua, blue, purple, magenta.
let mixerHues: [Float] = [0, 30, 60, 120, 180, 240, 270, 300]

/// Color Mixer (like Lightroom's HSL): hue, saturation and luminance per colour band. A pixel between two bands
/// gets a linear blend of their settings; greys and whites are left alone.
func colorMixer(_ x: RGB, _ p: Params) -> RGB {
    func band(_ a: [Double]?) -> [Float] { (a ?? []).count == 8 ? a!.map { Float($0) / 100 } : [Float](repeating: 0, count: 8) }
    let (H, S, L) = (band(p.hsl_hue), band(p.hsl_sat), band(p.hsl_lum))
    return x.map { _, r, g, b in
        let mx = max(r, g, b), c = mx - min(r, g, b)
        guard c > 1e-4, mx > 1e-4 else { return (r, g, b) }
        let h6 = mx == r ? (g - b) / c : mx == g ? (b - r) / c + 2 : (r - g) / c + 4
        let h = (h6 * 60 + 360).truncatingRemainder(dividingBy: 360)
        var k = 7
        while k > 0 && mixerHues[k] > h { k -= 1 }  // bands k and k+1 surround h (magenta wraps to red)
        let k1 = (k + 1) % 8, t = (h - mixerHues[k]) / ((k == 7 ? 360 : mixerHues[k1]) - mixerHues[k])
        let dh = H[k] + (H[k1] - H[k]) * t, ds = S[k] + (S[k1] - S[k]) * t, dl = L[k] + (L[k1] - L[k]) * t
        let sat = c / mx, wc = min(1, sat / 0.25)  // how colourful: greys barely move
        var (R, G, B) = dh == 0 ? (r, g, b) : hsv2rgb(h + dh * 30 * wc, sat, mx)  // hue: up to ±30°
        let y = luma(R, G, B), gain = 1 + ds  // saturation: 0…2x around the pixel's own luminance, so brightness holds
        (R, G, B) = (y + (R - y) * gain, y + (G - y) * gain, y + (B - y) * gain)
        let e = exp2f(dl * 1.2 * wc)  // luminance: up to ±1.2 stops, in linear light so hue and saturation hold
        return (srgb(lin(R) * e), srgb(lin(G) * e), srgb(lin(B) * e))
    }
}

func hsv2rgb(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
    let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
    let i = Int(hh), f = hh - Float(i), p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i % 6 {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

/// Pink lips inside the lip outline. t > 0: pinker (redder, cooler, a touch lighter); t < 0: towards a nude,
/// skin-beige lip (Lab a* 10, b* 14) rather than grey.
func pinkLips(_ x: RGB, _ faces: [Face], _ t: Float, _ s: Double) -> RGB {
    let m = lipMask(faces, x.w, x.h, s)
    return x.map { i, r, g, b in
        guard m[i] > 0 else { return (r, g, b) }
        let (L, A, B) = rgb2lab(r, g, b)
        let (R, G, Bl) = t > 0 ? lab2rgb(L + 3 * t, A + 14 * t, B - 10 * t) : lab2rgb(L - 4 * t, A + (10 - A) * 0.7 * -t, B + (14 - B) * 0.7 * -t)
        return (r + (R - r) * m[i], g + (G - g) * m[i], b + (Bl - b) * m[i])
    }
}

/// Filled lip outline from Vision's face landmarks, with the mouth opening cut out (teeth stay white), feathered.
func lipMask(_ faces: [Face], _ w: Int, _ h: Int, _ s: Double) -> [Float] {
    var px = [UInt8](repeating: 0, count: w * h)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        func poly(_ pts: [CGPoint], _ gray: CGFloat) {
            guard pts.count > 2 else { return }
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.addLines(between: pts.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) })
            ctx.closePath()
            ctx.fillPath()
        }
        for f in faces { poly(f.outerLips, 1); poly(f.innerLips, 0) }
    }
    return gauss(px.map { Float($0) / 255 }, w, h, max(1, 1.5 * s)).map { min(1, $0 * 1.5) }  // soft edge, not shrunk
}

// MARK: - Vision (same calls as flashmask.swift, so the mask matches byte for byte)

func analyze(_ cg: CGImage) throws -> (mask: [Float], faces: [Face]) {
    let img = CIImage(cgImage: cg), ext = img.extent, w = cg.width, h = cg.height
    let seg = VNGeneratePersonSegmentationRequest()
    seg.qualityLevel = .accurate
    let face = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(ciImage: img)
    try handler.perform([seg, face])
    var faces = (face.results ?? []).map { f -> Face in
        let b = VNImageRectForNormalizedRect(f.boundingBox, w, h)
        return Face(x: Int(b.minX), y: Int(ext.height - b.maxY), w: Int(b.width), h: Int(b.height))
    }
    // lip outlines for Pink lips, on the same faces (the boxes above stay exactly what flashmask reports)
    let marks = VNDetectFaceLandmarksRequest()
    marks.inputFaceObservations = face.results
    if (try? handler.perform([marks])) != nil {
        let size = CGSize(width: w, height: h)
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) } }
        for o in marks.results ?? [] {
            let b = VNImageRectForNormalizedRect(o.boundingBox, w, h), c = CGPoint(x: b.midX, y: size.height - b.midY)
            func d(_ f: Face) -> CGFloat { hypot(CGFloat(f.x) + CGFloat(f.w) / 2 - c.x, CGFloat(f.y) + CGFloat(f.h) / 2 - c.y) }
            guard let k = faces.indices.min(by: { d(faces[$0]) < d(faces[$1]) }) else { continue }
            (faces[k].outerLips, faces[k].innerLips) = (pts(o.landmarks?.outerLips), pts(o.landmarks?.innerLips))
        }
    }
    guard let buf = seg.results?.first?.pixelBuffer else { return ([Float](repeating: 0, count: w * h), faces) }
    var mask = CIImage(cvPixelBuffer: buf)
    mask = mask.transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width, y: ext.height / mask.extent.height))
    var bytes = [UInt8](repeating: 0, count: w * h)
    CIContext().render(mask.cropped(to: ext), toBitmap: &bytes, rowBytes: w, bounds: ext, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    return (bytes.map { Float($0) / 255 }, faces)
}

// MARK: - I/O

/// Loads an image upright. `maxSide` downsamples (for previews); nil = full resolution. For a video, the frame `time` seconds in.
func loadImage(_ url: URL, maxSide: Int? = nil, at time: Double = 0) -> CGImage? {
    if isVideoFile(url) { return videoFrame(url, at: time, maxSide: maxSide) }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    let side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    if (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1 && (maxSide ?? side) >= side {
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: min(maxSide ?? side, side)]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

/// Upright pixel size of the file, without decoding it.
func imageSize(_ url: URL) -> CGSize? {
    if isVideoFile(url) { return videoSize(url) }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ cg: CGImage) -> RGB {
    let (w, h) = (cg.width, cg.height)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func ch(_ c: Int) -> [Float] { fill(w * h) { Float(px[$0 * 4 + c]) / 255 } }
    return RGB(w: w, h: h, r: ch(0), g: ch(1), b: ch(2))
}

/// 8-bit output like PIL's (clip*255+0.5).astype(uint8), with the white "claude" tag of flashgrade.save(label=...).
func cgImage(_ x: RGB, label: String? = nil) -> CGImage {
    let (w, h) = (x.w, x.h)
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<w * h {
        px[i * 4] = UInt8(clip01(x.r[i]) * 255 + 0.5); px[i * 4 + 1] = UInt8(clip01(x.g[i]) * 255 + 0.5); px[i * 4 + 2] = UInt8(clip01(x.b[i]) * 255 + 0.5)
    }
    if let label { stamp(&px, w, h, label) }
    let data = CFDataCreate(nil, px, px.count)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: data)!,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// Small white tag in the top-left corner, with a soft shadow so it reads on bright skies.
/// Same geometry as PIL: Helvetica Neue at max(14, round(W*0.045)) px, ascender line at (round(W*0.035), round(W*0.03)).
private func stamp(_ px: inout [UInt8], _ w: Int, _ h: Int, _ label: String) {
    let W = Double(w), size = max(14, (W * 0.045).rounded(.toNearestOrEven))
    let x0 = (W * 0.035).rounded(.toNearestOrEven), y0 = (W * 0.03).rounded(.toNearestOrEven), blur = max(1, W / 400)
    let font = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    let bh = min(h, Int(y0 + size * 1.6 + 4 * blur) + 2)  // only the top band holds the tag
    var cov = [UInt8](repeating: 0, count: w * bh)
    cov.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: bh, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setShouldSmoothFonts(false)
        let str = NSAttributedString(string: label, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                 kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)])
        ctx.textPosition = CGPoint(x: x0, y: Double(bh) - y0 - ceil(CTFontGetAscent(font)))
        CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
    }
    let shadow = gauss(cov.map { (Float($0) * 110 / 255).rounded() }, w, bh, blur).map { $0.rounded() }
    for i in 0..<w * bh {
        let m = shadow[i] / 255, a = Float(cov[i]) / 255
        for c in 0..<3 {
            let v = (Float(px[i * 4 + c]) * (1 - m)).rounded()
            px[i * 4 + c] = UInt8((v + (255 - v) * a).rounded())
        }
    }
}

/// Writes JPEG, HEIC, PNG or TIFF by extension. `metadataFrom` copies the original's EXIF/GPS (date taken, camera,
/// location); the orientation is reset because the pixels are already upright.
func save(_ cg: CGImage, to url: URL, quality: Double = 0.95, metadataFrom source: URL? = nil) throws {
    let type = (UTType(filenameExtension: url.pathExtension) ?? .jpeg).identifier as CFString
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let source, let src = CGImageSourceCreateWithURL(source as CFURL, nil),
       let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] { props[key] = meta[key] }
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff }
        props[kCGImagePropertyOrientation] = 1
    }
    CGImageDestinationAddImage(dst, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dst) else { throw CocoaError(.fileWriteUnknown) }
}

/// Shrinks so the long edge is at most `longEdge` pixels (0 = keep the full size).
func resized(_ cg: CGImage, longEdge: Int) -> CGImage {
    let side = max(cg.width, cg.height)
    guard longEdge > 0, side > longEdge else { return cg }
    let k = Double(longEdge) / Double(side), w = max(1, Int(Double(cg.width) * k)), h = max(1, Int(Double(cg.height) * k))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? cg
}

/// "iPhone 15 Pro · 24 mm f/1.8 · ISO 80 · 1/120 s", from the photo's EXIF (empty when there is none).
func photoInfo(_ url: URL) -> String {
    if isVideoFile(url) { return videoInfo(url) }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return "" }
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:], tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    var parts: [String] = []
    if let m = tiff[kCGImagePropertyTIFFModel] as? String { parts.append(m) }
    if let f = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double ?? exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(f.rounded())) mm") }
    if let a = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "f/%.1f", a)) }
    if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
    if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 { parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s") }
    return parts.joined(separator: " · ")
}

/// Full-resolution render, as `python flashgrade.py in out preset` does.
/// `whole` carries the crop/straighten (defaults to `bg`). For a video, the frame `time` seconds in.
func render(_ url: URL, bg: Params, fg: Params, whole: Params? = nil, label: String? = nil, at time: Double = 0) throws -> (CGImage, Int) {
    guard let cg = loadImage(url, at: time) else { throw CocoaError(.fileReadCorruptFile) }
    let (M, faces) = try analyze(cg)
    return (cgImage(geometry(edit(rgb(cg), M, faces, bg: bg, fg: fg), whole ?? bg), label: label), faces.count)
}
