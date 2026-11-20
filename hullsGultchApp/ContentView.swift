import SwiftUI
import UIKit
import SceneKit
import Combine

struct ContentView: View {
    @State private var scene = PointCloudScene.make()
    @State private var useAR = false
    @StateObject private var arState = ARSessionState()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if useAR {
                ARContainer(state: arState)
                    .ignoresSafeArea()
            } else if let scene {
                SceneView(
                    scene: scene,
                    options: [.allowsCameraControl]
                )
                .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Point Cloud Preview Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("PointCloud.bin could not be loaded.")
                )
                .foregroundStyle(.white)
            }

            // Overlay guidance/status
            VStack(spacing: 8) {
                if useAR {
                    Text(arState.statusMessage ?? "Align the reference image and tap it to place.")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 50)
                }
                Spacer()
                if useAR {
                    TrackingChip(state: arState)
                        .padding(.bottom, 24)
                }
            }

            HStack {
                Spacer()
                Toggle(isOn: $useAR) {
                    Text("AR")
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .toggleStyle(.switch)
                .padding()
            }
        }
    }
}

/// Bottom-of-screen indicator: a colored dot, a one-line status, and (once placed) the
/// distance from the sign and the distance walked since placement.
private struct TrackingChip: View {
    @ObservedObject var state: ARSessionState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.trackingText)
                    .font(.subheadline.bold())
                if state.placed, let distance = state.distanceFromSign {
                    Text("Sign: \(Int(distance.rounded())) m  ·  Walked: \(Int(state.pathWalked.rounded())) m")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var dotColor: Color {
        switch state.trackingLevel {
        case .unknown: return .gray
        case .good:    return .green
        case .caution: return .yellow
        case .poor:    return .red
        }
    }
}

private enum PointCloudScene {
    static func make() -> SCNScene? {
        // 4 m wide on-screen preview (same size as before), with GCP markers.
        guard let node = TerrainModel.makeNode(longestSide: 4) else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(node)
        return scene
    }
}

private struct ARContainer: UIViewControllerRepresentable {
    let state: ARSessionState

    func makeUIViewController(context: Context) -> ARHostingController {
        // We use ARHostingController directly; UI overlay is handled by SwiftUI
        ARHostingController(referenceImageGroupName: "AR Resources", referenceImageName: nil, state: state)
    }

    func updateUIViewController(_ uiViewController: ARHostingController, context: Context) {}
}
