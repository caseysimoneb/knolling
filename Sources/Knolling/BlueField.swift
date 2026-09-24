import AppKit
import CoreImage

/// The menu's own backdrop: something seen through moving water. Pale forms — streaks and soft
/// blossoms in the warm white of the paper — over cyanotype blue, dragged by a horizontal motion blur, softened, then given a
/// fine film grain. Drawn fresh for each week (seeded by the week number).
enum BlueField {
    private static var cache: [Int: NSImage] = [:]

    static func image(seed: Int, size: CGSize = CGSize(width: 324, height: 900)) -> NSImage? {
        if let hit = cache[seed] { return hit }
        let scale: CGFloat = 2
        let w = CGFloat(size.width * scale), h = CGFloat(size.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = Seeded(seed)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

        // water: deep at the bottom, paler toward the top
        let water = CGGradient(colorsSpace: nil, colors: [color(0.66, 0.77, 0.85), color(0.22, 0.44, 0.72), color(0.10, 0.29, 0.57)] as CFArray,
                               locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

        // Prussian blue, leaning cyan; highlights are the warm paper of a cyanotype print
        let deep = [color(0.09, 0.27, 0.55), color(0.13, 0.35, 0.64), color(0.10, 0.31, 0.52)]
        let pale = [color(0.94, 0.93, 0.87), color(0.90, 0.91, 0.88), color(0.79, 0.86, 0.91), color(0.86, 0.89, 0.89)]
        func pick(_ list: [CGColor]) -> CGColor { list[Int(rng.next() * Double(list.count)) % list.count] }

        // deep currents
        for _ in 0..<6 {
            ctx.setFillColor(pick(deep).copy(alpha: 0.8)!)
            let rw = w * CGFloat(0.6 + rng.next() * 0.8), rh = h * CGFloat(0.05 + rng.next() * 0.1)
            ctx.fillEllipse(in: CGRect(x: w * CGFloat(rng.next()) - rw / 2, y: h * CGFloat(rng.next()) - rh / 2, width: rw, height: rh))
        }
        // pale streaks
        for _ in 0..<9 {
            ctx.setFillColor(pick(pale).copy(alpha: CGFloat(0.35 + rng.next() * 0.4))!)
            let rw = w * CGFloat(0.4 + rng.next() * 0.7), rh = h * CGFloat(0.015 + rng.next() * 0.04)
            ctx.fillEllipse(in: CGRect(x: w * CGFloat(rng.next()) - rw / 2, y: h * CGFloat(rng.next()) - rh / 2, width: rw, height: rh))
        }
        // soft blossoms
        for _ in 0..<18 {
            ctx.setFillColor(pick(pale).copy(alpha: CGFloat(0.7 + rng.next() * 0.3))!)
            let r = w * CGFloat(0.06 + rng.next() * 0.07)
            ctx.fillEllipse(in: CGRect(x: w * CGFloat(rng.next()) - r, y: h * CGFloat(rng.next()) - r * 0.8, width: 2 * r, height: 1.6 * r))
        }

        guard let drawn = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: drawn)
        let extent = input.extent

        let moved = input.clampedToExtent()
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 28 * scale, kCIInputAngleKey: 0.03])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5 * scale])
            .cropped(to: extent)

        // fine film grain, soft-lit in at low strength
        let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.22, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.22, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.22, w: 0),
                "inputBiasVector": CIVector(x: 0.39, y: 0.39, z: 0.39, w: 0)])
            .cropped(to: extent)
        let grained = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: moved])

        guard let out = CIContext().createCGImage(grained, from: extent) else { return nil }
        let image = NSImage(cgImage: out, size: size)
        cache[seed] = image
        return image
    }

    private struct Seeded {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
    }
}
