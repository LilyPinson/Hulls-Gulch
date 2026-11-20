import Foundation

/// Optional configuration to correct scale and tune rendering of the point cloud.
///
/// Provide this via a bundled JSON file named `PointCloudScale.json`.
/// You can specify either a direct `scaleFactor`, or the real-world
/// `expectedLongestSideMeters` from your report (the code will compute the ratio
/// against the cloud's current longest side). If both are provided, `scaleFactor` wins.
/// You can also specify the total horizontal area via 'expectedAreaSquareMeters'.
///
/// You can also tune the point rendering parameters. If these are nil, sensible defaults
/// will be used (derived from the cloud's voxel size when available).
struct PointCloudScaleConfig: Decodable {
    /// Real-world longest horizontal side of the site (meters).
    let expectedLongestSideMeters: Float?
    /// Direct multiplier to apply to the cloud's size.
    let scaleFactor: Float?
    /// Real-world horizontal area of the site (square meters). If provided, we scale uniformly so the cloud's X-Z area matches this value.
    let expectedAreaSquareMeters: Float?

    /// Size of each rendered point in scene meters (not screen pixels).
    let pointSizeMeters: Float?
    /// Minimum on-screen radius of each rendered point, in pixels.
    let minPointRadiusPx: Float?
    /// Maximum on-screen radius of each rendered point, in pixels.
    let maxPointRadiusPx: Float?

    /// Vertical exaggeration to highlight relief (1 = none). Not applied by default.
    let verticalExaggeration: Float?

    static func load(resource: String = "PointCloudScale", ext: String = "json") -> PointCloudScaleConfig? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
            // Optional file; it's fine if it's missing.
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PointCloudScaleConfig.self, from: data)
        } catch {
            print("[PointCloudScale] Could not decode \(resource).\(ext): \(error)")
            return nil
        }
    }

    /// Computes the effective scale to apply to the cloud given its current longest side.
    /// - Returns: `scaleFactor` if present; else ratio of expected/actual; else 1.
    func effectiveScaleFactor(actualLongestSideMeters: Float) -> Float {
        if let s = scaleFactor, s > 0 { return s }
        if let expected = expectedLongestSideMeters, expected > 0, actualLongestSideMeters > 0 {
            return expected / actualLongestSideMeters
        }
        return 1
    }
}
