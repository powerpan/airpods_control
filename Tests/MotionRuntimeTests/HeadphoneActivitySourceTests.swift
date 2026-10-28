import CoreMotion
import Foundation
import Testing
@testable import MotionRuntime

@available(macOS 15.0, *)
private func invokeActivityError(_ handler: @Sendable (CMMotionActivity?, (any Error)?) -> Void) -> Bool {
    let offMainThread = !Thread.isMainThread
    handler(nil, NSError(domain: "ActivityCallback", code: 42,
                         userInfo: [NSLocalizedDescriptionKey: "Synthetic activity error"]))
    return offMainThread
}

@Test @MainActor
func activityCallbackCreatedOnMainActorRunsOnDetachedTask() async {
    guard #available(macOS 15.0, *) else { return }
    let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream()
    let sink = ActivityEventSink(continuation)
    let handler = HeadphoneActivitySource.makeActivityHandler(sink: sink)
    let ranOffMain = await Task.detached { invokeActivityError(handler) }.value
    #expect(ranOffMain)
    var iterator = stream.makeAsyncIterator()
    guard case .failure(let message) = await iterator.next() else {
        Issue.record("背景活動回調應傳遞錯誤")
        return
    }
    #expect(message == "ActivityCallback (42): Synthetic activity error")
    #expect(sink.failureReason == message)
    #expect(!sink.isOpen)
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func emptyActivityCallbackRunsOnOperationQueue() async {
    guard #available(macOS 15.0, *) else { return }
    let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream()
    let sink = ActivityEventSink(continuation)
    let handler = HeadphoneActivitySource.makeActivityHandler(sink: sink)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let ranOffMain = await withCheckedContinuation { result in
        queue.addOperation {
            let offMainThread = !Thread.isMainThread
            handler(nil, nil)
            result.resume(returning: offMainThread)
        }
    }
    #expect(ranOffMain)
    var iterator = stream.makeAsyncIterator()
    guard case .failure(let message) = await iterator.next() else {
        Issue.record("空活動回調應中斷證據")
        return
    }
    #expect(message.contains("沒有包含資料或錯誤"))
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func statusCallbacksRunOffActorAndLateCallbacksAreIgnored() async {
    guard #available(macOS 15.0, *) else { return }
    let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream()
    let sink = ActivityEventSink(continuation)
    let handler = HeadphoneActivitySource.makeStatusHandler(sink: sink)
    await Task.detached {
        handler(.connected, nil)
        handler(.disconnected, nil)
    }.value
    sink.finish()
    await Task.detached { handler(.connected, nil) }.value
    #expect(sink.currentConnection == .disconnected)
    var iterator = stream.makeAsyncIterator()
    guard case .connection(.connected) = await iterator.next(),
          case .connection(.disconnected) = await iterator.next() else {
        Issue.record("應依序保留連接與斷開事件")
        return
    }
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func statusErrorCannotBeOverwrittenByLaterConnectedCallback() async {
    guard #available(macOS 15.0, *) else { return }
    let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream()
    let sink = ActivityEventSink(continuation)
    let handler = HeadphoneActivitySource.makeStatusHandler(sink: sink)
    await Task.detached {
        handler(.disconnected, NSError(domain: "ActivityStatus", code: 1))
        handler(.connected, nil)
    }.value
    #expect(sink.currentConnection == .unknown)
    #expect(sink.failureReason != nil)
    #expect(!sink.isOpen)
    var iterator = stream.makeAsyncIterator()
    guard case .failure = await iterator.next() else {
        Issue.record("狀態錯誤必須維持到下一代來源")
        return
    }
    #expect(await iterator.next() == nil)
}

@Test
func activityOverflowRetainsFailureAndClosesGeneration() async {
    let (stream, continuation) = AsyncStream<ActivitySourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let sink = ActivityEventSink(continuation)
    sink.yield(.connection(.connected))
    sink.yield(.connection(.disconnected))
    sink.yield(.connection(.connected))
    #expect(!sink.isOpen)
    #expect(sink.currentConnection == .disconnected)
    #expect(sink.failureReason?.contains("緩衝溢位") == true)
    var iterator = stream.makeAsyncIterator()
    guard case .failure(let message) = await iterator.next() else {
        Issue.record("丟失活動事件必須以 failure 結束，不能悄悄維持步行證據")
        return
    }
    #expect(message.contains("緩衝溢位"))
    #expect(await iterator.next() == nil)
}

@Test @MainActor
func unsupportedActivitySourceReportsReasonWithoutHardwareAccess() async {
    let source = UnavailableActivitySource(reason: "活動識別不可用；轉頭遮擋仍可使用。")
    #expect(!source.availability.isAvailable)
    #expect(!source.availability.isActive)
    var iterator = source.start().makeAsyncIterator()
    guard case .availability(let availability) = await iterator.next() else {
        Issue.record("降級來源必須說明不可用原因")
        return
    }
    #expect(availability.reason == "活動識別不可用；轉頭遮擋仍可使用。")
    #expect(await iterator.next() == nil)
    source.stop()
    source.stop()
}
