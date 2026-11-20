import Foundation
import SceneKit
import UIKit

/// Tunable AR settings.
enum ARConfig {
    /// Longest horizontal side of the terrain model in AR, in real-world meters.
    /// 1.0 m  ->  roughly a 1:300 tabletop miniature of the 250 x 310 m site.
    static let miniatureLongestSide: Float = 1.0
}

/// Builds the full scene content: the point cloud plus a marker for every GCP.
/// Everything inside the returned node is in real-world meters; the node itself carries
/// the miniature scale, so cloud and markers always stay registered to each other.
enum TerrainModel {
    /// - Parameter longestSide: target size (meters) of the model's longest horizontal side.
    ///   Pass nil for true 1:1 scale.
    static func makeNode(longestSide: Float?) -> SCNNode? {
        guard let meta = PointCloudMeta.load() else { return nil }

        // Optional correction and rendering parameters from PointCloudScale.json
        let scaleConfig = PointCloudScaleConfig.load()
        let reportHints = ReportIngestor.extractHints()

        // Derive sensible point rendering defaults from the voxel size when available.
        let defaultPointSize = max(0.6, Float(meta.voxelMeters) * 1.3)
        let pointSizeMeters = scaleConfig?.pointSizeMeters ?? reportHints?.recommendedPointSizeMeters ?? defaultPointSize
        let pointSize = CGFloat(pointSizeMeters)
        let minPx = CGFloat(scaleConfig?.minPointRadiusPx ?? reportHints?.minPointRadiusPx ?? 1.5)
        let maxPx = CGFloat(scaleConfig?.maxPointRadiusPx ?? reportHints?.maxPointRadiusPx ?? 6)

        guard let cloud = PointCloudBuilder.makeNode(pointSize: pointSize, minPointRadius: minPx, maxPointRadius: maxPx) else { return nil }

        let root = SCNNode()
        root.name = "Terrain"
        root.addChildNode(cloud)

        // Apply uniform scale correction (config wins, else PDF hints) and optional vertical exaggeration (Y only).
        let actualLongest = max(meta.extentMeters[0], meta.extentMeters[2])
        var correction: Float = 1

        // Compute uncorrected horizontal area (X-Z plane) from meta extents.
        let xExtent = max(0, meta.extentMeters[0])
        let zExtent = max(0, meta.extentMeters[2])
        let uncorrectedArea = xExtent * zExtent

        if let sc = scaleConfig {
            if let s = sc.scaleFactor, s > 0 {
                correction = s
            } else if let expected = sc.expectedLongestSideMeters, expected > 0, actualLongest > 0 {
                correction = expected / actualLongest
            } else if let expectedArea = sc.expectedAreaSquareMeters, expectedArea > 0, uncorrectedArea > 0 {
                correction = sqrtf(expectedArea / uncorrectedArea)
            } else if let expected = reportHints?.expectedLongestSideMeters, expected > 0, actualLongest > 0 {
                correction = expected / actualLongest
            }
        } else if let expected = reportHints?.expectedLongestSideMeters, expected > 0, actualLongest > 0 {
            correction = expected / actualLongest
        }
        let vEx = max(scaleConfig?.verticalExaggeration ?? reportHints?.verticalExaggeration ?? 1, 0)
        cloud.scale = SCNVector3(correction, correction * vEx, correction)

        // Same origin the Python script used, so markers land exactly on the cloud.
        let frame = GeoFrame(longitude: meta.origin.lon, latitude: meta.origin.lat, elevation: meta.origin.ele)
        for gcp in GCPLoader.load() {
            root.addChildNode(makeMarker(for: gcp, frame: frame))
        }

        if let target = longestSide {
            let longest = max(meta.extentMeters[0], meta.extentMeters[2]) * correction
            let s = longest > 0 ? target / longest : 1
            root.scale = SCNVector3(s, s, s)
        }
        return root
    }

    /// A pole + ball standing on the GCP's real position, with a billboarded label.
    private static func makeMarker(for gcp: GroundControlPoint, frame: GeoFrame) -> SCNNode {
        let base = frame.scenePosition(longitude: gcp.longitude, latitude: gcp.latitude, elevation: gcp.elevation)
        let poleHeight: CGFloat = 12

        let marker = SCNNode()
        marker.name = "GCP \(gcp.name)"
        marker.position = base

        let pole = SCNNode(geometry: SCNCylinder(radius: 0.25, height: poleHeight))
        pole.position = SCNVector3(0, Float(poleHeight / 2), 0)
        pole.geometry?.firstMaterial = flatMaterial(.systemRed)
        marker.addChildNode(pole)

        let ball = SCNNode(geometry: SCNSphere(radius: 1.6))
        ball.position = SCNVector3(0, Float(poleHeight), 0)
        ball.geometry?.firstMaterial = flatMaterial(.systemYellow)
        marker.addChildNode(ball)

        let text = SCNText(string: gcp.name, extrusionDepth: 0.1)
        text.font = UIFont.boldSystemFont(ofSize: 4)
        text.flatness = 0.1
        text.firstMaterial = flatMaterial(.white)
        let label = SCNNode(geometry: text)
        let (lo, hi) = text.boundingBox
        label.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
        label.position = SCNVector3(0, Float(poleHeight) + 3, 0)
        label.constraints = [SCNBillboardConstraint()]
        marker.addChildNode(label)

        return marker
    }

    private static func flatMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        return m
    }
}

