import SwiftUI

/// 设计稿图标：24 网格 SVG 路径，线宽 1.9、圆角端点、无填充。
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 24
    var weight: CGFloat = 1.9
    var filled = false

    init(_ icon: Icon, size: CGFloat = 24, weight: CGFloat = 1.9, filled: Bool = false) {
        self.icon = icon
        self.size = size
        self.weight = weight
        self.filled = filled
    }

    var body: some View {
        let path = SVGPath.cached(icon.path)
        Canvas { ctx, sz in
            let s = sz.width / 24
            let p = Path(path).applying(CGAffineTransform(scaleX: s, y: s))
            if filled { ctx.fill(p, with: .foreground) }
            ctx.stroke(p, with: .foreground,
                       style: StrokeStyle(lineWidth: weight * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 最小 SVG 路径解析（M L H V C S Q T A Z，大小写），足够渲染设计稿全部图标。
enum SVGPath {
    private static var cache: [String: CGPath] = [:]

    static func cached(_ d: String) -> CGPath {
        if let p = cache[d] { return p }
        let p = parse(d)
        cache[d] = p
        return p
    }

    static func parse(_ d: String) -> CGPath {
        var tokens = Tokens(d)
        let path = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        var cmd: Character = "M"
        while let c = tokens.command(defaultingTo: cmd) {
            cmd = c
            let rel = c.isLowercase
            func pt() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch c.uppercased().first! {
            case "M":
                guard let p = pt() else { return path }
                path.move(to: p); cur = p; start = p; lastCtrl = nil
                cmd = rel ? "l" : "L" // 后续坐标对视为 L
            case "L":
                guard let p = pt() else { return path }
                path.addLine(to: p); cur = p; lastCtrl = nil
            case "H":
                guard let x = tokens.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil
            case "V":
                guard let y = tokens.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2
            case "Q":
                guard let c1 = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c1); cur = p; lastCtrl = c1
            case "T":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c1); cur = p; lastCtrl = c1
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rot = tokens.number(),
                      let large = tokens.flag(), let sweep = tokens.flag(), let p = pt() else { return path }
                arc(path, from: cur, to: p, rx: rx, ry: ry, angle: rot, large: large, sweep: sweep)
                cur = p; lastCtrl = nil
            case "Z":
                path.closeSubpath(); cur = start; lastCtrl = nil
            default:
                return path
            }
        }
        return path
    }

    /// SVG 端点参数弧 → 中心参数，再用三次贝塞尔逼近。
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                            angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = angle * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segs = Int(ceil(abs(dt) / (.pi / 2)))
        let step = dt / CGFloat(segs)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = t1
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosP - ry * sin(t) * sinP, y: cy + rx * cos(t) * sinP + ry * sin(t) * cosP)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosP - ry * cos(t) * sinP, y: -rx * sin(t) * sinP + ry * cos(t) * cosP)
        }
        for _ in 0..<segs {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    private struct Tokens {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }

        /// 下一个命令字母；若下一个是数字则沿用上一个命令（隐式重复）。
        mutating func command(defaultingTo last: Character) -> Character? {
            skip()
            guard i < chars.count else { return nil }
            if chars[i].isLetter { defer { i += 1 }; return chars[i] }
            return last
        }

        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { i += 1 }
                else if c == ".", !dot { dot = true; i += 1 }
                else if c == "e" || c == "E" {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            guard i > begin else { return nil }
            return Double(String(chars[begin..<i])).map { CGFloat($0) }
        }
    }
}
