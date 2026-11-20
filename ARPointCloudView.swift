import SwiftUI
import ARKit
import SceneKit
import CoreLocation
import simd

/// Hosts the AR session. Flow: detect the trailhead sign -> user taps -> a miniature of the
/// terrain (with GCP markers) appears in front of the sign.
///
/// World alignment is `.gravityAndHeading`, so ARKit's world axes are +X east, +Y up, +Z south,
/// which is exactly the model's frame (x = east, y = up, z = -north). The terrain is therefore
/// placed with NO rotation and is automatically oriented to true north.
final class ARHostingController: UIViewController {
    private let arView = ARSCNView(frame: .zero)
    private let referenceImageGroupName: String
    private let referenceImageName: String?
    private let state: ARSessionState
    private let locationManager = CLLocationManager()   // needed for heading alignment

    // Main-thread only.
    private var pendingImageTransform: simd_float4x4?
    private var placementRequested = false

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
        locationManager.requestWhenInUseAuthorization()
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }

    private func startSession() {
        guard let refImages = ARReferenceImage.referenceImages(inGroupNamed: referenceImageGroupName, bundle: .main) else {
            state.statusMessage = "Reference images not found in the asset catalog."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
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

    // MARK: - Main-thread handlers

    private func handleImageDetected(_ transform: simd_float4x4) {
        guard !placementRequested else { return }
        pendingImageTransform = transform
        state.imageDetected = true
        state.statusMessage = "Sign detected. Tap the screen to place the terrain."
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !placementRequested, let imageTransform = pendingImageTransform else { return }
        placementRequested = true

        let imagePos = SIMD3<Float>(imageTransform.columns.3.x, imageTransform.columns.3.y, imageTransform.columns.3.z)

        // For an ARImageAnchor the image lies in the X-Z plane and the Y axis is the NORMAL
        // pointing out of the image face (toward the reader). Flatten it to get the direction
        // that leads away from the sign, toward the person.
        let normal = SIMD3<Float>(imageTransform.columns.1.x, 0, imageTransform.columns.1.z)
        let outward = simd_length(normal) > 0.1 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 0)

        // Ground height below the sign if a floor plane is known, else ~1 m below the sign.
        let query = ARRaycastQuery(origin: imagePos,
                                   direction: SIMD3<Float>(0, -1, 0),
                                   allowing: .existingPlaneGeometry,
                                   alignment: .horizontal)
        let groundY = arView.session.raycast(query).first?.worldTransform.columns.3.y ?? (imagePos.y - 1.0)

        // Put the miniature's center in front of the sign, clear of the sign itself.
        let distance = ARConfig.miniatureLongestSide / 2 + 0.3
        let pos = SIMD3<Float>(imagePos.x, groundY, imagePos.z) + outward * distance

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
            DispatchQueue.main.async { [weak self] in self?.handleImageDetected(transform) }
            return
        }

        if anchor.name == "PointCloudWorldAnchor" {
            guard let terrain = TerrainModel.makeNode(longestSide: nil) else {
                DispatchQueue.main.async { [weak self] in
                    self?.state.statusMessage = "Could not load PointCloud.bin."
                    self?.placementRequested = false
                }
                return
            }
            node.addChildNode(terrain)
            DispatchQueue.main.async { [weak self] in
                self?.state.placed = true
                self?.state.statusMessage = "Placed at 1:1 scale. Walk through the landscape."
            }
        }
    }
}
