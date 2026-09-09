import Foundation
import simd

/// Recovers MapKit's ground homography from four public coordinate conversions.
/// Extends it vertically using camera heading/pitch, so altitude, attitude and perspective
/// share one world space. No private MapKit camera APIs or guessed field of view.
struct MapProjection {
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    let up: SIMD3<Double>
    let origin: SIMD3<Double>
    let depthScale: Double
    let width: Double
    let height: Double

    init?(screenPoints: [SIMD2<Double>], sampleMeters: Double, width: Double, height: Double,
          heading: Double, pitch: Double, cameraDistance: Double) {
        guard screenPoints.count == 4, width > 0, height > 0 else { return nil }
        let ground: [SIMD2<Double>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        var rows: [[Double]] = []
        for (p, s) in zip(ground, screenPoints) {
            rows.append([p.x, p.y, 1, 0, 0, 0, -s.x * p.x, -s.x * p.y, s.x])
            rows.append([0, 0, 0, p.x, p.y, 1, -s.y * p.x, -s.y * p.y, s.y])
        }
        guard let h = Self.solve(rows) else { return nil }
        east = SIMD3(h[0], h[3], h[6]) / sampleMeters
        north = SIMD3(h[1], h[4], h[7]) / sampleMeters
        origin = SIMD3(h[2], h[5], 1)
        let a = heading.radians
        let p = pitch.radians
        let right = east * cos(a) - north * sin(a)
        let forward = east * sin(a) + north * cos(a)
        let scale: Double
        let cx: Double
        let cy: Double
        let focal = right.x
        if abs(sin(p)) > 0.05 {
            scale = forward.z / sin(p)
            cx = forward.x / sin(p)
            cy = (forward.y + focal * cos(p)) / sin(p)
        } else {
            scale = 1 / max(1, cameraDistance)
            cx = origin.x * scale
            cy = origin.y * scale
        }
        guard scale.isFinite, scale > 0, focal > 0 else { return nil }
        depthScale = scale
        up = SIMD3(-cx * cos(p), -focal * sin(p) - cy * cos(p), -scale * cos(p))
        self.width = width
        self.height = height
    }

    /// Scene coordinates: +X east, +Y up, -Z north. Aircraft nose points -Z.
    var matrix: simd_float4x4 {
        let near = 0.5
        let far = 2_000_000.0
        let a = (far + near) / (far - near)
        let b = 2 * far * near / (far - near)
        func column(_ h: SIMD3<Double>, constant: Bool = false) -> SIMD4<Float> {
            SIMD4(Float(2 * h.x / width - h.z), Float(h.z - 2 * h.y / height),
                  Float(a * h.z - (constant ? b * depthScale : 0)), Float(h.z))
        }
        return simd_float4x4(columns: (column(east), column(up), column(-north), column(origin, constant: true)))
    }

    func project(east x: Double, north y: Double, altitude: Double) -> SIMD3<Double> {
        let h = east * x + north * y + up * altitude + origin
        return SIMD3(h.x / h.z, h.y / h.z, h.z)
    }

    private static func solve(_ input: [[Double]]) -> [Double]? {
        var a = input
        let count = a.count
        for col in 0..<count {
            let pivot = (col..<count).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[pivot][col]) > 1e-10 else { return nil }
            a.swapAt(col, pivot)
            let divisor = a[col][col]
            for j in col...count { a[col][j] /= divisor }
            for row in 0..<count where row != col {
                let multiplier = a[row][col]
                for j in col...count { a[row][j] -= multiplier * a[col][j] }
            }
        }
        let result = a.map { $0[count] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}
