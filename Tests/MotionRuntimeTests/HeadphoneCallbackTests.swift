import CoreMotion
import Foundation
import Testing
@testable import MotionRuntime

/// Check the executing thread and invoke the synchronous framework callback
/// without a suspension between them. Thread identity is not task identity.
private func invokeErrorCallback(_ handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void) -> Bool {
    let offMainThread = !Thread.isMainThread
    handler(nil, NSError(
        domain: "CallbackRegression", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "Synthetic callback error"]
    ))
    return offMainThread
}

@Test @MainActor
func headphoneErrorCallbackCreatedOnMainActorRunsOnADetachedTask() async {
    let (stream, continuation) = AsyncStream<MotionSourceEvent>.makeStream()
    let sink = EventSink(continuation)
    // Construct from the same actor as HeadphoneMotionSource.start(). The
    // actual callback must retain no MainActor isolation when Core Motion
    // delivers it on its operation queue.
    let handler = HeadphoneMotionSource.makeHandler(sink: sink)
    let ranOffMainThread = await Task.detached {
        invokeErrorCallback(handler)
    }.value
    #expect(ranOffMainThread)
    sink.finish()
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    guard case .failure(let message) = event else {
        Issue.record("Expected the background error callback to yield a failure event")
        return
    }
    #expect(message == "CallbackRegression (42): Synthetic callback error")
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func headphoneEmptyCallbackCreatedOnMainActorRunsOnAnOperationQueue() async {
    let (stream, continuation) = AsyncStream<MotionSourceEvent>.makeStream()
    let sink = EventSink(continuation)
    let handler = HeadphoneMotionSource.makeHandler(sink: sink)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "HeadphoneCallbackTests.Background"
    let ranOffMainThread = await withCheckedContinuation { continuation in
        queue.addOperation {
            let offMainThread = !Thread.isMainThread
            handler(nil, nil)
            continuation.resume(returning: offMainThread)
        }
    }
    #expect(ranOffMainThread)
    sink.finish()
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    guard case .failure(let message) = event else {
        Issue.record("Expected a nil-data background callback to yield a failure event")
        return
    }
    #expect(message.contains("没有包含数据或错误"))
    #expect(await iterator.next() == nil)
}
