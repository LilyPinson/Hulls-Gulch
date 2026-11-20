import Foundation
import SceneKit

/// Contents of PointCloudMeta.json (written by prepare_pointcloud.py).
struct PointCloudMeta: Decodable {
    struct Origin: Decodable {
        let lon: Double
        let lat: Double
        let ele: Double
    }
    let count: Int
    let voxelMeters: Double
    let origin: Origin
    /// [east, up, north] size of the cloud in meters.
    let extentMeters: [Float]

    static func load(resource: String = "PointCloudMeta", ext: String = "json") -> PointCloudMeta? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            print("[PointCloud] \(resource).\(ext) not found in bundle.")
            return nil
        }
        do {
            return try JSONDecoder().decode(PointCloudMeta.self, from: data)
        } catch {
            print("[PointCloud] Could not decode \(resource).\(ext): \(error)")
            return nil
        }
    }
}

enum PointCloudBuilder {
    /// Bytes per point in PointCloud.bin: float32 x,y,z + uint8 r,g,b,a.
    private static let stride = 16

    /// Builds a point-cloud node from `PointCloud.bin`.
    ///
    /// Coordinates are already in scene meters (x = east, y = up, z = -north), so no
    /// geodetic math happens here. The node is NOT scaled; scale the parent instead.
    static func makeNode(
        resource: String = "PointCloud",
        ext: String = "bin",
        pointSize: CGFloat = 0.6,          // in scene meters (cloud voxel is 0.45 m)
        minPointRadius: CGFloat = 1.5,     // screen pixels – keeps a tiny model visible
        maxPointRadius: CGFloat = 6
    ) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            print("[PointCloud] \(resource).\(ext) not found in bundle.")
            return nil
        }
        let count = data.count / stride
        guard count > 0, data.count % stride == 0 else {
            print("[PointCloud] \(resource).\(ext) has an unexpected size (\(data.count) bytes).")
            return nil
        }

        // Positions come straight out of the file (zero copy): offset 0, stride 16.
        let positionSource = SCNGeometrySource(
            data: data,
            semantic: .vertex,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: stride
        )

        // Colors: uint8 RGBA at byte offset 12 -> float RGBA.
        var colors = [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let o = i * stride + 12
                colors[i] = SIMD4<Float>(Float(raw[o]) / 255, Float(raw[o + 1]) / 255, Float(raw[o + 2]) / 255, 1)
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indices = (0..<count).map { Int32($0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        // Tunable via PointCloudScale.json (see PointCloudScaleConfig).
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = minPointRadius
        element.maximumPointScreenSpaceRadius = maxPointRadius

        let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "PointCloud"
        return node
    }
}
