import Foundation
import SceneKit

extension TerrainModel {
    /// Position of the named GCP in terrain scene coordinates (meters; x = east, y = up, z = -north),
    /// computed exactly the way the GCP markers are placed, so it matches what's drawn on the cloud.
    /// Returns nil if the metadata is missing or no GCP matches `name`.
    static func scenePosition(ofGCPNamed name: String) -> SIMD3<Float>? {
        guard let meta = PointCloudMeta.load() else { return nil }
        let frame = GeoFrame(longitude: meta.origin.lon, latitude: meta.origin.lat, elevation: meta.origin.ele)

        // Match on the text so it works whether the stored name is "777" or something like "GCP 777".
        let gcps = GCPLoader.load()
        guard let gcp = gcps.first(where: { "\($0.name)" == name })
                ?? gcps.first(where: { "\($0.name)".contains(name) }) else { return nil }

        let p = frame.scenePosition(longitude: gcp.longitude, latitude: gcp.latitude, elevation: gcp.elevation)
        return SIMD3<Float>(p.x, p.y, p.z)
    }
}
