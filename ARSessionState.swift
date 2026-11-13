import Foundation
import Combine

final class ARSessionState: ObservableObject {
    @Published var imageDetected: Bool = false
    @Published var placed: Bool = false
    @Published var statusMessage: String? = nil
}
