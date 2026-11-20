import Foundation
import Combine

/// How trustworthy the terrain placement currently is.
enum TrackingLevel {
    case unknown   // session just started
    case good      // tracking normal, you're near the sign and moving calmly
    case caution   // tracking normal, but drift is likely (far from sign / long walk / moving fast)
    case poor      // ARKit itself reports limited or lost tracking
}

final class ARSessionState: ObservableObject {
    @Published var imageDetected: Bool = false
    @Published var placed: Bool = false
    @Published var statusMessage: String? = nil

    // Tracking / drift monitoring (updated about 4 times per second by ARHostingController).
    @Published var trackingLevel: TrackingLevel = .unknown
    @Published var trackingText: String = "Starting AR..."
    /// Horizontal distance from the camera to the sign, in meters. nil until the sign is seen.
    @Published var distanceFromSign: Float? = nil
    /// Meters walked since the terrain was placed.
    @Published var pathWalked: Float = 0
    /// Smoothed walking speed in meters per second.
    @Published var speed: Float = 0

    /// Called each time AR mode is entered so stale values from a previous session don't linger.
    func reset() {
        imageDetected = false
        placed = false
        statusMessage = nil
        trackingLevel = .unknown
        trackingText = "Starting AR..."
        distanceFromSign = nil
        pathWalked = 0
        speed = 0
    }
}
