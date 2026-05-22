import Foundation

/// Bundled sample document so the demo can run without filesystem fiddling.
/// Pick any topic you like — the text is small enough for one-pass retrieval but rich
/// enough that BM25 + a language model can produce a real cited answer.
enum SampleDocument {
    static let sourceId = "swift-concurrency"
    static let name = "Swift Concurrency Notes"

    static let text = """
    # Swift Concurrency Notes

    ## Tasks and Structured Concurrency

    Swift's structured concurrency model uses `Task` to spawn asynchronous work.
    Tasks inherit priority and actor context from their parent. A detached task,
    created with `Task.detached`, breaks this inheritance and is reserved for work
    that genuinely should not carry the parent's context.

    ## Actors

    An actor is a reference type that protects its mutable state with serial access.
    Calling an actor method from outside the actor requires `await` because the call
    may suspend. Inside the actor, the same calls are synchronous.

    Actors can opt into global isolation with `@MainActor`. UI code in SwiftUI lives
    on the main actor by default, which is why view properties update without locks.

    ## Sendable and Strict Concurrency

    Types that cross actor boundaries must conform to `Sendable`. Value types of
    `Sendable` properties are automatically `Sendable`; reference types must be
    declared `final class … : Sendable` and prove they protect their state, or
    annotate themselves `@unchecked Sendable` and take responsibility manually.

    With Swift 6's strict concurrency, the compiler refuses to compile data-race
    risks. The typical fix is to bind a captured value to a local `let` before
    handing a closure across an actor boundary, or to make the captured type
    explicitly `Sendable`.

    ## AsyncSequence and AsyncStream

    `AsyncSequence` is the asynchronous analogue of `Sequence`: each iteration
    awaits the next element. `AsyncStream` and `AsyncThrowingStream` build one
    from a `Continuation` so non-async APIs (delegates, notifications) can be
    bridged into the async world. Set `continuation.onTermination` to clean up
    when consumers stop iterating early.
    """
}
