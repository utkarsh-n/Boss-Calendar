import CoreMotion
import Observation

/// Gravity → filtered screen-space tilt for the dial's decorative light (Metro Station spec §13).
/// Portrait-only app, so no orientation remapping is needed.
@MainActor
@Observable
final class TiltService {
    private(set) var vector = SIMD2<Double>.zero
    private(set) var isActive = false

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var reference = SIMD2<Double>.zero
    @ObservationIgnored private var hasReference = false
    @ObservationIgnored private var generation = 0

    func start() {
        guard manager.isDeviceMotionAvailable, !isActive else { return }
        isActive = true
        hasReference = false
        generation += 1
        let run = generation
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] update, error in
            let gx = update?.gravity.x, gz = update?.gravity.z
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.generation == run else { return }
                if failed { self.stop(); return }
                guard let gx, let gz else { return }
                if !self.hasReference {
                    self.reference = SIMD2(gx, gz)
                    self.hasReference = true
                }
                let target = SIMD2(min(1, max(-1, 1.7 * (gx - self.reference.x))),
                                   min(1, max(-1, 1.7 * (gz - self.reference.y))))
                self.vector += 0.18 * (target - self.vector)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isActive = false
        hasReference = false
        vector = .zero
    }
}
