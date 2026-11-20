import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import simd

/// Starting-point thresholds for the tracking indicator. These are guesses; tune them after you
/// see how the numbers look on the real site.
private enum DriftThresholds {
    /// Farther than this from the sign (meters, horizontal) -> "drift likely".
    static let cautionDistance: Float = 100
    /// Walked more than this since placement (meters) -> "drift likely".
    static let cautionPath: Float = 60
    /// Walking faster than this (m/s) -> "slow down". A brisk walk is about 1.5 m/s.
    static let fastSpeed: Float = 2.0
    /// Position changes implying more than this speed (m/s) are treated as a tracking jump
    /// (e.g. relocalization), not as walking, so they don't inflate the distance walked.
    static let maxPlausibleSpeed: Float = 6.0
}

/// Hosts the AR session. Flow: detect the trailhead sign -> user taps -> the terrain
/// (with GCP markers) is placed at the sign, at life size or as a miniature.
///
/// World alignment is `.gravityAndHeading`, so ARKit's world axes are +X east, +Y up, +Z south,
/// which is exactly the model's frame (x = east, y = up, z = -north). The terrain is therefore
/// placed with NO rotation and is automatically oriented to true north.
final class ARHostingController: UIViewController {
    /// true  -> real-world size (1 scene meter = 1 real meter), you stand inside the landscape.
    /// false -> tabletop miniature (`ARConfig.miniatureLongestSide`).
    private static let lifeSize = true

    /// The GCP that sits at (or next to) the trailhead sign. At life size this point is
    /// placed on the ground at the sign, which registers the terrain to the real world.
    private static let referenceGCPName = "777"

    private let arView = ARSCNView(frame: .zero)
    private let referenceImageGroupName: String
    private let referenceImageName: String?
    private let state: ARSessionState
    private let locationManager = CLLocationManager()   // needed for heading alignment

    // Main-thread only.
    private var pendingImageTransform: simd_float4x4?
    private var placementRequested = false

    // Tracking / drift monitoring (main-thread only).
    private var monitorTimer: Timer?
    private var trackingState: ARCamera.TrackingState = .notAvailable
    private var signPosition: SIMD3<Float>?          // world position of the detected sign
    private var lastCameraPosition: SIMD3<Float>?
    private var lastTickTime: TimeInterval?
    private var smoothedSpeed: Float = 0
    private var pathSincePlacement: Float = 0

    init(referenceImageGroupName: String = "AR Resources", referenceImageName: String? = nil, state: ARSessionState) {
        self.referenceImageGroupName = referenceImageGroupName
        self.referenceImageName = referenceImageName
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = arView
        arView.delegate = self
        arView.automaticallyUpdatesLighting = true
        arView.scene = SCNScene()
        #if DEBUG
        arView.debugOptions.insert(.showFeaturePoints)
        #endif
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        state.reset()
        locationManager.requestWhenInUseAuthorization()
        startSession()
        startMonitoring()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopMonitoring()
        arView.session.pause()
    }

    private func startSession() {
        guard let refImages = ARReferenceImage.referenceImages(inGroupNamed: referenceImageGroupName, bundle: .main) else {
            state.statusMessage = "Reference images not found in the asset catalog."
            return
        }
        // Debug: shows the sign size ARKit is really using (compare with the real sign).
        for image in refImages {
            print("[AR] reference image '\(image.name ?? "?")' declared size: \(image.physicalSize.width) x \(image.physicalSize.height) m")
        }
        let configuration = ARWorldTrackingConfiguration()
        // Lets ARKit correct the sign's size if the declared width is a bit off.
        configuration.automaticImageScaleEstimationEnabled = true
        configuration.worldAlignment = .gravityAndHeading
        if let name = referenceImageName, let image = refImages.first(where: { $0.name == name }) {
            configuration.detectionImages = [image]
        } else {
            configuration.detectionImages = refImages
        }
        configuration.maximumNumberOfTrackedImages = 1
        configuration.planeDetection = [.horizontal]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Tracking / drift monitor

    private func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.monitorTick()
        }
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    /// Runs about 4 times per second on the main thread.
    private func monitorTick() {
        guard let frame = arView.session.currentFrame else { return }
        let t = frame.camera.transform.columns.3
        let cameraPosition = SIMD3<Float>(t.x, t.y, t.z)
        let now = frame.timestamp

        // Distance walked and walking speed, from how far the camera moved since the last tick.
        if let last = lastCameraPosition, let lastTime = lastTickTime, now > lastTime {
            let step = simd_distance(cameraPosition, last)
            let speed = step / Float(now - lastTime)
            if speed <= DriftThresholds.maxPlausibleSpeed {
                smoothedSpeed = smoothedSpeed * 0.6 + speed * 0.4
                if placementRequested { pathSincePlacement += step }
            }
        }
        lastCameraPosition = cameraPosition
        lastTickTime = now

        // Horizontal distance from the sign (height differences don't matter for drift).
        var distance: Float? = nil
        if let sign = signPosition {
            distance = simd_length(SIMD2<Float>(cameraPosition.x - sign.x, cameraPosition.z - sign.z))
        }

        let (level, text) = evaluateTracking(distance: distance)
        state.trackingLevel = level
        state.trackingText = text
        state.distanceFromSign = distance
        state.pathWalked = pathSincePlacement
        state.speed = smoothedSpeed
    }

    /// Combines ARKit's own tracking state with our drift estimates into one indicator.
    private func evaluateTracking(distance: Float?) -> (TrackingLevel, String) {
        switch trackingState {
        case .notAvailable:
            return (.poor, "Tracking unavailable")
        case .limited(let reason):
            switch reason {
            case .initializing:         return (.caution, "Initializing...")
            case .excessiveMotion:      return (.poor, "Slow down")
            case .insufficientFeatures: return (.poor, "Point at more detail")
            case .relocalizing:         return (.poor, "Relocalizing...")
            @unknown default:           return (.poor, "Tracking limited")
            }
        case .normal:
            if placementRequested {
                if smoothedSpeed > DriftThresholds.fastSpeed {
                    return (.caution, "Slow down")
                }
                if let distance, distance > DriftThresholds.cautionDistance {
                    return (.caution, "Far from sign: drift likely")
                }
                if pathSincePlacement > DriftThresholds.cautionPath {
                    return (.caution, "Long walk: drift likely")
                }
            }
            return (.good, "Tracking good")
        }
    }

    // MARK: - Main-thread handlers

    private func handleImageDetected(_ transform: simd_float4x4) {
        guard !placementRequested else { return }
        pendingImageTransform = transform
        signPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        state.imageDetected = true
        state.statusMessage = "Sign detected. Tap the screen to place the terrain."
    }

    /// Best estimate of the ground height (ARKit world Y) below `point`.
    /// 1) a detected floor plane, 2) an estimated plane, 3) ~1.4 m below the phone.
    private func groundHeight(below point: SIMD3<Float>) -> Float {
        let down = SIMD3<Float>(0, -1, 0)
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let query = ARRaycastQuery(origin: point, direction: down, allowing: target, alignment: .horizontal)
            if let hit = arView.session.raycast(query).first {
                return hit.worldTransform.columns.3.y
            }
        }
        if let cameraY = arView.session.currentFrame?.camera.transform.columns.3.y {
            return cameraY - 1.4
        }
        return point.y - 1.0
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !placementRequested, let imageTransform = pendingImageTransform else { return }
        placementRequested = true
        pathSincePlacement = 0   // start counting distance walked from the moment of placement

        let imagePos = SIMD3<Float>(imageTransform.columns.3.x, imageTransform.columns.3.y, imageTransform.columns.3.z)

        // For an ARImageAnchor the image lies in the X-Z plane and the Y axis is the NORMAL
        // pointing out of the image face (toward the reader). Flatten it to get the direction
        // that leads away from the sign, toward the person.
        let normal = SIMD3<Float>(imageTransform.columns.1.x, 0, imageTransform.columns.1.z)
        let outward = simd_length(normal) > 0.1 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 0)

        let groundY = groundHeight(below: imagePos)

        let signGround = SIMD3<Float>(imagePos.x, groundY, imagePos.z)
        let pos: SIMD3<Float>
        if Self.lifeSize {
            // Life size: slide the whole terrain so the reference GCP (the one at the trailhead)
            // lands exactly on the ground at the sign. Horizontal AND vertical.
            if let reference = TerrainModel.scenePosition(ofGCPNamed: Self.referenceGCPName) {
                pos = signGround - reference
            } else {
                print("[AR] GCP \(Self.referenceGCPName) not found; placing the cloud origin at the sign instead.")
                pos = signGround
            }
        } else {
            // Miniature: center the model in front of the sign, clear of the sign itself.
            pos = signGround + outward * (ARConfig.miniatureLongestSide / 2 + 0.3)
        }

        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1)   // translation only (north-aligned)
        arView.session.add(anchor: ARAnchor(name: "PointCloudWorldAnchor", transform: world))
        state.statusMessage = "Placing..."
    }
}

extension ARHostingController: ARSCNViewDelegate {
    // Called on SceneKit's render thread: touch SwiftUI/UIKit state only via the main queue.
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let imageAnchor = anchor as? ARImageAnchor {
            let transform = imageAnchor.transform
            print("[AR] sign detected. Declared width: \(imageAnchor.referenceImage.physicalSize.width) m, estimatedScaleFactor: \(imageAnchor.estimatedScaleFactor)")
            DispatchQueue.main.async { [weak self] in self?.handleImageDetected(transform) }
            return
        }

        if anchor.name == "PointCloudWorldAnchor" {
            let longestSide: Float? = Self.lifeSize ? nil : ARConfig.miniatureLongestSide
            guard let terrain = TerrainModel.makeNode(longestSide: longestSide) else {
                DispatchQueue.main.async { [weak self] in
                    self?.state.statusMessage = "Could not load PointCloud.bin."
                    self?.placementRequested = false
                }
                return
            }
            node.addChildNode(terrain)
            let message = Self.lifeSize
                ? "Placed at life size. Walk through the landscape."
                : "Placed. Walk around the model to explore."
            DispatchQueue.main.async { [weak self] in
                self?.state.placed = true
                self?.state.statusMessage = message
            }
        }
    }

    // ARSCNViewDelegate also covers ARSessionObserver, so ARKit reports tracking changes here.
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let newState = camera.trackingState
        DispatchQueue.main.async { [weak self] in self?.trackingState = newState }
    }
}
