import MapKit
import SceneKit
import SwiftUI

struct AircraftMapView: UIViewRepresentable {
    let store: TrackerStore
    var isActive: Bool

    func makeUIView(context: Context) -> AircraftMapContainer {
        AircraftMapContainer(store: store)
    }

    func updateUIView(_ view: AircraftMapContainer, context: Context) {
        view.setActive(isActive)
    }

    static func dismantleUIView(_ uiView: AircraftMapContainer, coordinator: ()) { uiView.setActive(false) }
}

@MainActor
final class AircraftMapContainer: UIView, MKMapViewDelegate, UIGestureRecognizerDelegate {
    private let store: TrackerStore
    let map = MKMapView()
    private let sceneView = SCNView()
    private let hud = AircraftHUDView()
    private let scene = SCNScene()
    private let camera = SCNNode()
    private let template = AircraftModel.make()
    private var nodes: [String: SCNNode] = [:]
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTarget?
    private var userMovedMap = false
    private var lastRevision = -1
    private var lastFollowUpdate: CFTimeInterval = 0
    private var nextStatusUpdate: CFTimeInterval = 0
    private var followDistance: Double?

    init(store: TrackerStore) {
        self.store = store
        super.init(frame: .zero)
        map.delegate = self
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.showsCompass = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.layoutMargins = UIEdgeInsets(top: 150, left: 16, bottom: 320, right: 16)
        addSubview(map)

        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.isUserInteractionEnabled = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = false
        sceneView.autoenablesDefaultLighting = false
        camera.camera = SCNCamera()
        camera.camera?.wantsHDR = false
        scene.rootNode.addChildNode(camera)
        sceneView.pointOfView = camera
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_200
        sun.eulerAngles = SCNVector3(-0.7, -0.5, 0)
        scene.rootNode.addChildNode(sun)
        addSubview(sceneView)
        hud.isUserInteractionEnabled = false
        hud.backgroundColor = .clear
        hud.isOpaque = false
        addSubview(hud)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        map.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        map.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        sceneView.frame = bounds
        hud.frame = bounds
    }

    func setActive(_ active: Bool) {
        guard active != (displayLink != nil) else { return }
        if active {
            let target = DisplayTarget(view: self)
            displayTarget = target
            let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
            displayTarget = nil
            sceneView.isPlaying = false
        }
    }

    func applyCameraCommand() {
        guard lastRevision != store.cameraRevision else { return }
        lastRevision = store.cameraRevision
        userMovedMap = false
        followDistance = nil
        let pitch: CGFloat = store.is3D ? 58 : 0
        if store.isFollowing, let track = store.selected {
            let pose = track.pose(at: .now)
            let distance = max(5_000, pose.altitude / cos(Double(pitch).radians) + 5_000)
            followDistance = distance
            let center = target(for: pose, pitch: pitch, heading: map.camera.heading)
            map.setCamera(MKMapCamera(lookingAtCenter: center, fromDistance: distance, pitch: pitch, heading: map.camera.heading), animated: false)
        } else if store.selectedID == nil {
            map.setCamera(MKMapCamera(lookingAtCenter: store.queryCenter.coordinate, fromDistance: 180_000,
                                     pitch: pitch, heading: 0), animated: false)
        } else {
            let c = map.camera.copy() as! MKMapCamera
            c.pitch = pitch
            map.setCamera(c, animated: false)
        }
    }

    private func target(for pose: FlightPose, pitch: CGFloat, heading: Double) -> CLLocationCoordinate2D {
        // MapKit targets the ground. Aim beyond the aircraft so its true altitude stays in frame.
        pose.position.destination(meters: pose.altitude * tan(Double(pitch).radians), bearing: heading).coordinate
    }

    fileprivate func frame(_ link: CADisplayLink) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        applyCameraCommand()
        let date = Date.now
        let tracks = store.renderTracks(at: date)
        if store.isFollowing, let selected = tracks.first(where: { $0.id == store.selectedID }), link.timestamp - lastFollowUpdate > 1 / 30 {
            let pose = selected.pose(at: date)
            let current = map.camera
            let distance = followDistance ?? current.centerCoordinateDistance
            map.setCamera(MKMapCamera(lookingAtCenter: target(for: pose, pitch: current.pitch, heading: current.heading),
                                     fromDistance: distance, pitch: current.pitch, heading: current.heading), animated: false)
            lastFollowUpdate = link.timestamp
        }
        let distance = map.camera.centerCoordinateDistance
        if link.timestamp > nextStatusUpdate {
            if abs(store.cameraDistance - distance) > 50 { store.cameraDistance = distance }
            nextStatusUpdate = link.timestamp + 0.3
        }
        let origin = MKMapPoint(map.camera.centerCoordinate)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(map.camera.centerCoordinate.latitude)
        let sample = min(8_000, max(100, distance * 0.08))
        let offsets: [SIMD2<Double>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        let samples = offsets.map { offset -> SIMD2<Double> in
            let p = MKMapPoint(x: origin.x + offset.x * sample / metersPerPoint, y: origin.y - offset.y * sample / metersPerPoint)
            let screen = map.convert(p.coordinate, toPointTo: map)
            return SIMD2(screen.x, screen.y)
        }
        let projection = MapProjection(screenPoints: samples, sampleMeters: sample,
                                       width: bounds.width, height: bounds.height,
                                       heading: map.camera.heading, pitch: Double(map.camera.pitch), cameraDistance: distance)
        let useModels = distance < TrackerStore.modelThreshold && projection != nil
        sceneView.isHidden = !useModels
        if let projection { camera.camera?.projectionTransform = SCNMatrix4(projection.matrix) }

        let ids = Set(tracks.map(\.id))
        for id in Array(nodes.keys) where !ids.contains(id) { nodes.removeValue(forKey: id)?.removeFromParentNode() }
        var markers: [AircraftHUDView.Marker] = []
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for track in tracks {
            let pose = track.pose(at: date)
            let point = MKMapPoint(pose.position.coordinate)
            let x = (point.x - origin.x) * metersPerPoint
            let north = (origin.y - point.y) * metersPerPoint
            let selected = track.id == store.selectedID
            let ground = map.convert(pose.position.coordinate, toPointTo: map)
            var screen = ground
            var inFront = true
            if useModels, let projection {
                let p = projection.project(east: x, north: north, altitude: pose.altitude)
                screen = CGPoint(x: p.x, y: p.y)
                inFront = p.z > 0.001
                let node: SCNNode
                if let existing = nodes[track.id] { node = existing } else {
                    node = template.clone()
                    scene.rootNode.addChildNode(node)
                    nodes[track.id] = node
                }
                node.simdPosition = SIMD3(Float(x), Float(pose.altitude), Float(-north))
                node.simdOrientation = simd_quatf(angle: Float(-pose.heading.radians), axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: Float(pose.pitch.radians), axis: SIMD3(1, 0, 0))
                    * simd_quatf(angle: Float(-pose.roll.radians), axis: SIMD3(0, 0, 1))
                node.simdScale = SIMD3(repeating: Float(store.modelScale))
                node.opacity = date.timeIntervalSince(track.flight.observedAt) > 90 ? 0.4 : 1
                node.isHidden = !inFront
            }
            if inFront, screen.x.isFinite, screen.y.isFinite, bounds.insetBy(dx: -60, dy: -60).contains(screen) {
                markers.append(.init(id: track.id, point: screen, ground: ground, heading: pose.heading - map.camera.heading,
                                     callsign: track.flight.callsign, selected: selected, isModel: useModels))
            }
        }
        SCNTransaction.commit()
        hud.markers = markers
        hud.setNeedsDisplay()
        // A single main-thread frame loop owns SceneKit mutations; no render-delegate races.
        sceneView.setNeedsDisplay()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let p = recognizer.location(in: hud)
        if let marker = hud.markers.min(by: { hypot($0.point.x - p.x, $0.point.y - p.y) < hypot($1.point.x - p.x, $1.point.y - p.y) }),
           hypot(marker.point.x - p.x, marker.point.y - p.y) < 40 {
            store.select(marker.id)
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { userMovedMap = true; store.isFollowing = false; followDistance = nil }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if userMovedMap, !store.isFollowing { store.queryCenter = GeoPoint(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude) }
        if store.isFollowing { followDistance = mapView.camera.centerCoordinateDistance }
    }

    @MainActor private final class DisplayTarget: NSObject {
        weak var view: AircraftMapContainer?
        init(view: AircraftMapContainer) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.frame(link) }
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

@MainActor
final class AircraftHUDView: UIView {
    struct Marker {
        let id: String
        let point: CGPoint
        let ground: CGPoint
        let heading: Double
        let callsign: String
        let selected: Bool
        let isModel: Bool
    }
    var markers: [Marker] = []
    private let plane = UIImage(systemName: "airplane", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))?
        .withTintColor(UIColor(red: 0.25, green: 0.86, blue: 0.96, alpha: 1), renderingMode: .alwaysOriginal)

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for marker in markers {
            if marker.selected {
                context.setStrokeColor(UIColor.cyan.withAlphaComponent(0.4).cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [3, 5])
                if marker.isModel {
                    context.move(to: marker.ground)
                    context.addLine(to: marker.point)
                    context.strokePath()
                    context.strokeEllipse(in: CGRect(x: marker.ground.x - 5, y: marker.ground.y - 5, width: 10, height: 10))
                }
                context.setLineDash(phase: 0, lengths: [])
                context.strokeEllipse(in: CGRect(x: marker.point.x - 31, y: marker.point.y - 31, width: 62, height: 62))
            }
            if !marker.isModel {
                context.saveGState()
                context.translateBy(x: marker.point.x, y: marker.point.y)
                context.rotate(by: CGFloat((marker.heading - 90).radians))
                context.setShadow(offset: .zero, blur: 4, color: UIColor.black.cgColor)
                plane?.draw(in: CGRect(x: -13, y: -13, width: 26, height: 26))
                context.restoreGState()
            }
            if marker.selected || (!marker.isModel && markers.count < 35) {
                let text = marker.callsign as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: UIColor.white]
                let size = text.size(withAttributes: attributes)
                let box = CGRect(x: marker.point.x - size.width / 2 - 6, y: marker.point.y + 35, width: size.width + 12, height: 20)
                UIColor(red: 0.03, green: 0.07, blue: 0.12, alpha: 0.88).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 5).fill()
                text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 4), withAttributes: attributes)
            }
        }
    }
}
