import Foundation
import SceneKit

public enum PointCloudScaleMode {
    case fitToExtent(Float) // largest dimension -> meters
    case preserveMeters
}

public enum PointCloudBuilder {
    /// Loads a CSV file from the main bundle and returns an `SCNNode` containing a point cloud geometry.
    /// The CSV is expected to have lines of the form: x,y,z,r,g,b (where colors are 0..1 floats).
    /// - Parameters:
    ///   - resource: The base name of the CSV resource in the main bundle.
    ///   - ext: The file extension (default: "csv").
    ///   - interpretAsGeodeticDegrees: If true, interprets x,y as longitude,latitude degrees and z as meters elevation.
    ///   - scaleMode: Scaling mode for the point cloud.
    /// - Returns: A node with point geometry centered at origin, or nil if loading fails.
    public static func makeNodeFromCSV(
        resource: String = "PointCloudPreview",
        ext: String = "csv",
        interpretAsGeodeticDegrees: Bool = true,
        scaleMode: PointCloudScaleMode = .fitToExtent(4),
        scaleMultiplier: Float = 1.0,
        pointSize: CGFloat = 10,
        minPointRadius: CGFloat = 4,
        maxPointRadius: CGFloat = 18,
        materialOpacity: CGFloat = 0.95
    ) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let text = try? String(contentsOf: url) else {
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

        // Convert from input space to local meters.
        let localPositions: [SIMD3<Float>]
        if interpretAsGeodeticDegrees {
            // Interpret x,y as longitude,latitude in degrees; z as distance/elevation in meters.
            // Map to local meters with:
            //  - X: east-west (meters) from longitude delta
            //  - Y: elevation (meters) from z delta
            //  - Z: north-south (meters) from latitude delta
            let centerLatDegrees = center.y
            let metersPerLatitudeDegree: Float = 111_320
            let metersPerLongitudeDegree = metersPerLatitudeDegree * cos(centerLatDegrees * .pi / 180)

            localPositions = rawPositions.map { p in
                let dx = (p.x - center.x) * metersPerLongitudeDegree
                let dy = (p.z - center.z) // z already in meters
                let dz = (p.y - center.y) * metersPerLatitudeDegree
                return SIMD3(dx, dy, dz)
            }
        } else {
            // Generic: center the data in its native units
            localPositions = rawPositions.map { $0 - center }
        }

        // Compute extents in local units (meters if geodetic)
        var minLocal = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxLocal = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in localPositions {
            minLocal = simd_min(minLocal, p)
            maxLocal = simd_max(maxLocal, p)
        }
        let extents = maxLocal - minLocal

        // Determine scale factor
        let scale: Float
        switch scaleMode {
        case .fitToExtent(let targetMeters):
            let largestDimension = max(extents.x, max(extents.y, extents.z))
            scale = largestDimension > 0 ? (targetMeters / largestDimension) : 1
        case .preserveMeters:
            scale = 1
        }

        // Build geometry
        let positions = localPositions.map { SCNVector3($0 * (scale * scaleMultiplier)) }
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
        points.pointSize = pointSize
        points.minimumPointScreenSpaceRadius = minPointRadius
        points.maximumPointScreenSpaceRadius = maxPointRadius

        let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [points])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = materialOpacity
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        return node
    }
}
