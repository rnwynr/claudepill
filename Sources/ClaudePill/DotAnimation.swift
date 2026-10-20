import Foundation

/// Continuous light fields on fixed 3×3 anchors, shared by both agents.
enum DotAnimation: String, CaseIterable {
    case wave, ripple, helix, settle, weave, propeller, reference
    case zipper, radar, echo, tide, crosswind, cascade, equalizer, ember

    var period: Double {
        switch self {
        case .wave: 1.30
        case .ripple: 1.50
        case .helix: 1.60
        case .settle: 1.10
        case .weave: 1.80
        case .propeller: 2.40
        case .reference: 1.08
        case .zipper: 1.40
        case .radar: 1.90
        case .echo: 2.10
        case .tide: 1.80
        case .crosswind: 2.60
        case .cascade: 1.70
        case .equalizer: 2.40
        case .ember: 2.80
        }
    }

    func brightness(cell: Int, time: Double) -> Double {
        let row = Double(cell / 3), col = Double(cell % 3)
        let x = col - 1, y = row - 1, q = Self.fract(time / period)
        let tau = 2 * Double.pi
        let v: Double
        switch self {
        case .wave:
            v = Self.envelope(Self.fract(q - (col + row) * 0.11), 0.10, 0.16)
        case .ripple:
            v = Self.envelope(Self.fract(q - (abs(x) + abs(y)) * 0.14), 0.08, 0.14)
        case .weave:
            let u = (cell / 3 + cell % 3) % 2 == 0 ? q - row * 0.17 : q - 0.5 - col * 0.17
            v = Self.envelope(Self.fract(u), 0.10, 0.15)
        case .helix:
            let phi = tau * q - col * tau / 3
            let a = pow(max(0, 1 - abs(row - (1 + sin(phi)))), 1.5)
            let b = pow(max(0, 1 - abs(row - (1 - sin(phi)))), 1.5)
            v = max(a, 0.55 * b)
        case .settle:
            let u = Self.fract(q - col * 0.14)
            let position = 2 * (1 - 4 * u * (1 - u))
            v = pow(max(0, 1 - abs(row - position) * 1.3), 1.4)
        case .propeller:
            v = cell == 4 ? 0.85 : pow(cos(atan2(y, x) - tau * q), 8)
        case .reference:
            let position = q * 9, index = Int(floor(position)), f = Self.fract(position)
            func frame(_ step: Int) -> Double {
                let age = (step - Self.referencePath.firstIndex(of: cell)! + 9) % 9
                let b = exp(-Double(age) / 1.5)
                return b < 0.05 ? 0 : b
            }
            v = Self.interpolate(frame(index), frame((index + 1) % 9), f)
        case .zipper:
            let position = q * 5, index = Int(floor(position)), f = Self.fract(position)
            func frame(_ step: Int) -> Double {
                let age = (step - Self.zipperSteps[cell] + 5) % 5
                return exp(-Double(age) / 0.85)
            }
            v = Self.interpolate(frame(index), frame((index + 1) % 5), f)
        case .radar:
            if cell == 4 {
                v = 0.22 + 0.14 * pow(max(0, sin(q * tau)), 3)
            } else {
                let angle = Self.fract((atan2(y, x) + .pi / 2) / tau)
                v = Self.envelope(Self.fract(q - angle), 0.035, 0.12)
            }
        case .echo:
            let u = Self.fract(q - (abs(x) + abs(y)) * 0.105)
            v = max(Self.envelope(u, 0.055, 0.09), 0.70 * Self.envelope(Self.fract(u - 0.22), 0.055, 0.09))
        case .tide:
            let position = 1 - cos(q * tau)
            v = exp(-pow((row - position) / 0.62, 2)) * (0.82 + 0.18 * cos(col * .pi / 2 - q * tau))
        case .crosswind:
            let sweep = q < 0.5 ? col : 2 - row
            let light = Self.envelope(Self.fract(Self.fract(q * 2) - sweep * 0.13), 0.085, 0.145)
            v = cell == 4 ? max(light, 0.18 * pow(sin(q * tau), 2)) : light
        case .cascade:
            v = Self.envelope(Self.fract(q - col * 0.18 - row * 0.075), 0.035, 0.075)
        case .equalizer:
            let phase = col * tau / 3
            let height = 1.15 + 0.65 * sin(q * tau + phase) + 0.25 * sin(q * tau * 2 - phase)
            let level = min(1, max(0, height - (2 - row) + 0.35))
            v = level * level * (3 - 2 * level)
        case .ember:
            let u = Self.fract(q - Self.emberPhases[cell])
            v = pow(max(0, sin(u * tau)), 6) * (0.68 + 0.32 * pow(cos(Double(cell) * 1.37), 2))
        }
        return v < 0.03 ? 0 : min(1, max(0, v))
    }

    private static let referencePath = [0, 1, 2, 5, 4, 3, 6, 7, 8]
    private static let zipperSteps = [0, 1, 2, 3, 4, 3, 2, 1, 0]
    private static let emberPhases = [0.08, 0.49, 0.77, 0.64, 0.22, 0.91, 0.37, 0.84, 0.56]
    private static func fract(_ x: Double) -> Double { x - floor(x) }
    private static func attack(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func envelope(_ u: Double, _ attackTime: Double, _ decay: Double) -> Double {
        u < attackTime ? attack(u / attackTime) : exp(-(u - attackTime) / decay)
    }
    private static func interpolate(_ a: Double, _ b: Double, _ f: Double) -> Double {
        a + (b - a) * (b > a ? attack(min(f * 1.8, 1)) : f)
    }
}
