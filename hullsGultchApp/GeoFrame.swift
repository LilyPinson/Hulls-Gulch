import Foundation
import SceneKit

/// A local tangent-plane frame around a geodetic origin.
///
/// SceneKit / ARKit convention used everywhere in this project (right-handed, Y-up):
///     +X = east,  +Y = up,  -Z = north   (so +Z = south)
///
/// All math is done in Double. This mirrors `GeoFrame` in prepare_pointcloud.py exactly,
/// so the point cloud (converted offline) and the GCP markers (converted at runtime)
/// share one coordinate system.
struct GeoFrame {
    let originLongitude: Double
    let originLatitude: Double
    let originElevation: Double
    let metersPerDegreeLongitude: Double
    let metersPerDegreeLatitude: Double

    // WGS84
    private static let semiMajor = 6_378_137.0
    private static let eccentricitySquared = 0.00669437999014

    init(longitude: Double, latitude: Double, elevation: Double) {
        originLongitude = longitude
        originLatitude = latitude
        originElevation = elevation

        let phi = latitude * .pi / 180
        let s2 = sin(phi) * sin(phi)
        let e2 = GeoFrame.eccentricitySquared
        let a = GeoFrame.semiMajor
        let primeVertical = a / (1 - e2 * s2).squareRoot()
        let meridional = a * (1 - e2) / pow(1 - e2 * s2, 1.5)
        metersPerDegreeLongitude = (.pi / 180) * primeVertical * cos(phi)
        metersPerDegreeLatitude = (.pi / 180) * meridional
    }

    /// Converts a real-world position to scene meters relative to the origin.
    func scenePosition(longitude: Double, latitude: Double, elevation: Double) -> SCNVector3 {
        let east = (longitude - originLongitude) * metersPerDegreeLongitude
        let north = (latitude - originLatitude) * metersPerDegreeLatitude
        let up = elevation - originElevation
        return SCNVector3(Float(east), Float(up), Float(-north))
    }
}

/// A surveyed ground control point (WGS84 degrees, elevation in meters).
struct GroundControlPoint {
    let name: String
    let longitude: Double
    let latitude: Double
    let elevation: Double
}

enum GCPLoader {
    /// Loads `GCP_locations.csv` (header: name,lon,lat,ele) from the main bundle.
    /// Tolerates CRLF line endings, a header row, and a missing trailing newline.
    static func load(resource: String = "GCP_locations", ext: String = "csv") -> [GroundControlPoint] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("[GCP] \(resource).\(ext) not found in bundle – no markers will be shown.")
            return []
        }

        var points: [GroundControlPoint] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // The header row fails the Double parse and is skipped automatically.
            guard fields.count >= 4,
                  let lon = Double(fields[1]),
                  let lat = Double(fields[2]),
                  let ele = Double(fields[3]) else { continue }
            points.append(GroundControlPoint(name: fields[0], longitude: lon, latitude: lat, elevation: ele))
        }
        return points
    }
}
