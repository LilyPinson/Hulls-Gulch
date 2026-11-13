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
                    description: Text("The preview file could not be loaded.")
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

private enum PointCloudScene {
    static func make() -> SCNScene? {
        guard let node = PointCloudBuilder.makeNodeFromCSV() else { return nil }
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
