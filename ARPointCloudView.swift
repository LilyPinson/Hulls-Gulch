import SwiftUI
import ARKit
import SceneKit
import simd

struct ARPointCloudView: UIViewRepresentable {
    @ObservedObject var state: ARSessionState

    /// The name of the AR Resource Group in the asset catalog containing reference images.
    var referenceImageGroupName: String = "AR Resources"
    /// Optional: name of a specific image to match (if nil, use all in group)
    var referenceImageName: String? = nil

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        // Show feature points to help users understand tracking
        view.debugOptions.insert(.showFeaturePoints)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Nothing dynamic for now.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self, state: state)
    }

    class Coordinator: NSObject, ARSCNViewDelegate {
        private let parent: ARPointCloudView
        private let state: ARSessionState
        private var hasPlaced = false

        init(_ parent: ARPointCloudView, state: ARSessionState) {
            self.parent = parent
            self.state = state
            super.init()
        }

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard let imageAnchor = anchor as? ARImageAnchor else { return }

            DispatchQueue.main.async { [weak self] in
                self?.state.imageDetected = true
                self?.state.statusMessage = "Image detected. Tap to place."
            }

            placePointCloud(onto: node, for: imageAnchor)
        }

        private func placePointCloud(onto node: SCNNode, for imageAnchor: ARImageAnchor) {
            guard !hasPlaced else { return }

            guard let cloudNode = PointCloudBuilder.makeNodeFromCSV(interpretAsGeodeticDegrees: true, scaleMode: .preserveMeters) else { return }

            // Orient the point cloud to lie flat on the detected image plane (X-right, Z-forward, Y-up in ARKit)
            // ARImageAnchor's transform gives a plane lying in the X-Y plane with Z pointing out of the image.
            // We want the cloud aligned so that its up (Y) is ARKit's up. Our builder uses Y as elevation, which already matches ARKit's up.
            // Slightly raise above the image to avoid z-fighting.
            cloudNode.position = SCNVector3(0, 0.002, 0)

            node.addChildNode(cloudNode)
            hasPlaced = true

            DispatchQueue.main.async { [weak self] in
                self?.state.placed = true
                self?.state.statusMessage = "Placed."
            }
        }
    }
}

extension ARPointCloudView {
    static func makeSessionConfiguration(referenceImageGroupName: String, referenceImageName: String?) -> ARWorldTrackingConfiguration? {
        guard let refImages = ARReferenceImage.referenceImages(inGroupNamed: referenceImageGroupName, bundle: .main) else {
            return nil
        }
        let configuration = ARWorldTrackingConfiguration()
        if let name = referenceImageName, let image = refImages.first(where: { $0.name == name }) {
            configuration.detectionImages = [image]
        } else {
            configuration.detectionImages = refImages
        }
        configuration.maximumNumberOfTrackedImages = 1
        configuration.planeDetection = [.horizontal]
        return configuration
    }
}

// A hosting controller to manage the AR session lifecycle from SwiftUI.
final class ARHostingController: UIViewController {
    private let arView = ARSCNView(frame: .zero)
    private let referenceImageGroupName: String
    private let referenceImageName: String?
    private let state: ARSessionState
    private var hasPlaced = false
    private var pendingImageTransform: simd_float4x4?
    private var pendingGroundY: Float?
    private var pendingYaw: Float?

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
        arView.debugOptions.insert(.showFeaturePoints)
        arView.debugOptions.insert(.showWorldOrigin)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }

    private func startSession() {
        guard let configuration = ARPointCloudView.makeSessionConfiguration(referenceImageGroupName: referenceImageGroupName, referenceImageName: referenceImageName) else { return }
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func makeTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    private func makeRotationY(_ radians: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>( cos(radians), 0, -sin(radians), 0)
        m.columns.2 = SIMD4<Float>( sin(radians), 0,  cos(radians), 0)
        return m
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !hasPlaced, let imageTransform = pendingImageTransform else { return }
        let imagePos = SIMD3<Float>(imageTransform.columns.3.x, imageTransform.columns.3.y, imageTransform.columns.3.z)
        let yaw = pendingYaw ?? 0
        let groundY = pendingGroundY ?? imagePos.y
        let pos = SIMD3<Float>(imagePos.x, groundY, imagePos.z)

        // Offset the anchor slightly forward from the sign so the cloud is in front of the user
        let forwardOffset: Float = 0.3
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw)) * forwardOffset

        let world = makeTranslation(pos) * makeRotationY(yaw) * makeTranslation(forward)
        let worldAnchor = ARAnchor(name: "PointCloudWorldAnchor", transform: world)
        arView.session.add(anchor: worldAnchor)
        state.statusMessage = "Placing..."
    }
}

extension ARHostingController: ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        // On image detection, compute yaw and try to find ground Y
        if let imageAnchor = anchor as? ARImageAnchor, !hasPlaced {
            pendingImageTransform = imageAnchor.transform
            // Compute yaw from the image's normal projected onto the horizontal plane
            let zAxis = SIMD3<Float>(imageAnchor.transform.columns.2.x, imageAnchor.transform.columns.2.y, imageAnchor.transform.columns.2.z)
            let flat = simd_normalize(SIMD3<Float>(zAxis.x, 0, zAxis.z))
            let yaw = atan2(flat.x, flat.z)
            pendingYaw = yaw

            // Raycast downward from the image position to find ground plane
            let origin = SIMD3<Float>(imageAnchor.transform.columns.3.x, imageAnchor.transform.columns.3.y, imageAnchor.transform.columns.3.z)
            let customQuery = ARRaycastQuery(origin: origin,
                                             direction: SIMD3<Float>(0, -1, 0),
                                             allowing: .existingPlaneGeometry,
                                             alignment: .horizontal)
            let results = arView.session.raycast(customQuery)
            if let first = results.first {
                pendingGroundY = first.worldTransform.columns.3.y
            }

            state.imageDetected = true
            state.statusMessage = "Image detected. Tap the image to place."
            return
        }

        // When the world anchor is created, attach the point cloud
        if anchor.name == "PointCloudWorldAnchor" {
            guard !hasPlaced else { return }
            if let cloudNode = PointCloudBuilder.makeNodeFromCSV(interpretAsGeodeticDegrees: true,
                                                                 scaleMode: .preserveMeters,
                                                                 scaleMultiplier: 2.0,
                                                                 pointSize: 14,
                                                                 minPointRadius: 6,
                                                                 maxPointRadius: 24,
                                                                 materialOpacity: 1.0) {
                // Keep cloud aligned with world up; no extra tilt
                cloudNode.position = SCNVector3(0, 0.02, 0) // slight lift above ground
                node.addChildNode(cloudNode)
                hasPlaced = true
                state.placed = true
                state.statusMessage = "Placed."
            }
        }
    }
}
