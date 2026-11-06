import SwiftUI
import SceneKit

struct ContentView: View {
    @State private var scene = PointCloudScene.make()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let scene {
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
        }
    }
}

private enum PointCloudScene {
    static func make() -> SCNScene? {
        guard let url = Bundle.main.url(
            forResource: "PointCloudPreview",
            withExtension: "csv"
        ), let text = try? String(contentsOf: url) else {
            return nil
        }

        var rawPositions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        text.enumerateLines { line, _ in
            let values = line.split(separator: ",").compactMap { Float($0) }
            guard values.count == 6 else { return }

            let position = SIMD3(values[0], values[1], values[2])
            rawPositions.append(position)
            colors.append(SIMD4(values[3], values[4], values[5], 1))
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }

        guard !rawPositions.isEmpty else { return nil }

        let center = (minimum + maximum) / 2
        let metersPerLatitudeDegree: Float = 111_320
        let metersPerLongitudeDegree = metersPerLatitudeDegree * cos(center.y * .pi / 180)

        // Convert GPS coordinates to local meters. SceneKit uses Y as the vertical axis,
        // so elevation becomes Y and north/south becomes depth.
        let localPositions = rawPositions.map { position in
            SIMD3(
                (position.x - center.x) * metersPerLongitudeDegree,
                position.z - center.z,
                (position.y - center.y) * metersPerLatitudeDegree
            )
        }
        let localExtents = SIMD3(
            (maximum.x - minimum.x) * metersPerLongitudeDegree,
            maximum.z - minimum.z,
            (maximum.y - minimum.y) * metersPerLatitudeDegree
        )
        let largestDimension = max(localExtents.x, localExtents.y, localExtents.z)
        let scale = largestDimension > 0 ? 4 / largestDimension : 1
        let positions = localPositions.map { SCNVector3($0 * scale) }
        let positionSource = SCNGeometrySource(vertices: positions)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let indices = (0..<positions.count).map(Int32.init)
        let points = SCNGeometryElement(indices: indices, primitiveType: .point)
        points.pointSize = 5
        points.minimumPointScreenSpaceRadius = 2
        points.maximumPointScreenSpaceRadius = 10

        let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [points])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return scene
    }
}
