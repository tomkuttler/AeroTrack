import SceneKit
import UIKit
import simd

@MainActor
enum AircraftModel {
    /// One shared, procedural 40 m jet. Geometry/materials are reused by node clones.
    /// Model axes: nose -Z, right wing +X, roof +Y. Metres, centered at the fuselage.
    static func make() -> SCNNode {
        let root = SCNNode()
        let pearl = material(UIColor(red: 0.87, green: 0.93, blue: 0.99, alpha: 1), metal: 0.35)
        let blue = material(UIColor(red: 0.08, green: 0.49, blue: 0.96, alpha: 1), metal: 0.45)
        let dark = material(UIColor(red: 0.04, green: 0.10, blue: 0.18, alpha: 1), metal: 0.2)
        let fuselage = SCNCapsule(capRadius: 1.85, height: 39)
        fuselage.radialSegmentCount = 20
        fuselage.capSegmentCount = 8
        let body = add(fuselage, material: pearl, to: root)
        body.eulerAngles.x = .pi / 2

        let cockpit = add(SCNSphere(radius: 1), material: dark, to: root)
        cockpit.scale = SCNVector3(1.45, 0.75, 2.1)
        cockpit.position = SCNVector3(0, 1.15, -15.5)

        // Swept, solid wings rather than a flat billboard.
        let wings = wing(points: [(-18, 7), (-18, 9), (-2, 4), (2, 4), (18, 9), (18, 7), (3, -4), (-3, -4)], thickness: 0.48)
        let wingNode = add(wings, material: pearl, to: root)
        wingNode.position.y = -0.7
        let tail = wing(points: [(-7, 17), (-7, 18), (7, 18), (7, 17), (1, 12), (-1, 12)], thickness: 0.3)
        add(tail, material: blue, to: root).position.y = 0.4

        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0, y: 11))
        finPath.addLine(to: CGPoint(x: 6.5, y: 17.5))
        finPath.addLine(to: CGPoint(x: 6.5, y: 19))
        finPath.addLine(to: CGPoint(x: 0, y: 19))
        finPath.close()
        let fin = add(SCNShape(path: finPath, extrusionDepth: 0.45), material: blue, to: root)
        fin.simdOrientation = simd_quatf(simd_float3x3(columns: (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))))

        for x: Float in [-6, 6] {
            let engine = add(SCNCylinder(radius: 1.1, height: 5), material: blue, to: root)
            engine.eulerAngles.x = .pi / 2
            engine.position = SCNVector3(x, -2, 0)
            let intake = add(SCNCylinder(radius: 0.84, height: 0.15), material: dark, to: root)
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(x, -2, -2.55)
        }
        for (x, color) in [(-17.8, UIColor.systemRed), (17.8, UIColor.systemGreen)] {
            let lightMaterial = material(color)
            lightMaterial.emission.contents = color
            let light = add(SCNSphere(radius: 0.35), material: lightMaterial, to: root)
            light.position = SCNVector3(x, -0.4, 7.5)
        }
        return root
    }

    private static func wing(points: [(Double, Double)], thickness: CGFloat) -> SCNGeometry {
        // The node rotates this X/Y outline into the aircraft's X/Z plane.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: points[0].0, y: -points[0].1))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.0, y: -p.1)) }
        path.close()
        return SCNShape(path: path, extrusionDepth: thickness)
    }

    @discardableResult private static func add(_ geometry: SCNGeometry, material: SCNMaterial, to root: SCNNode) -> SCNNode {
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        if geometry is SCNShape { node.eulerAngles.x = -.pi / 2 }
        root.addChildNode(node)
        return node
    }

    private static func material(_ color: UIColor, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.metalness.contents = metal
        m.roughness.contents = 0.42
        m.isDoubleSided = true
        return m
    }
}
