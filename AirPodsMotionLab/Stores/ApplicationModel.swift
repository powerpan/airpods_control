import Foundation
import MotionRuntime

@MainActor
final class ApplicationModel {
    let motion: MotionStore
    let features: InteractionStore
    private var activated = false

    init() {
        let sharedSession = MotionSession()
        motion = MotionStore(session: sharedSession)
        features = InteractionStore(motion: sharedSession)
    }

    func activate() async {
        guard !activated else { return }
        activated = true
        if ProcessInfo.processInfo.arguments.contains("--simulate") {
            await motion.session.setSource(.simulation)
            await motion.session.start()
        }
        motion.activate()
        features.activate()
    }

    func shutdown() async {
        await features.shutdown()
        await motion.shutdown()
    }
}
