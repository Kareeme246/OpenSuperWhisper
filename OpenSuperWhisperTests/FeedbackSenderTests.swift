import XCTest

@testable import OpenSuperWhisper

/// Records what the Feedback card would have posted and answers from a canned reply. Every test
/// goes through it: a real request lands in the owner's inbox.
private final class FeedbackTransportStub {
    enum Reply {
        case status(Int)
        case failure(URLError.Code)
    }

    private let reply: Reply
    /// The transport runs off the main actor while the test reads from it.
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    /// When holding, a send waits here until `release()`, so a test can look at it mid-flight.
    private var holds: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(reply: Reply = .status(200), holds: Bool = false) {
        self.reply = reply
        self.holds = holds
    }

    var sender: FeedbackSender {
        FeedbackSender(transport: { [self] request in
            lock.withLock { sent.append(request) }
            if lock.withLock({ holds }) {
                await withCheckedContinuation { continuation in
                    lock.withLock { gate = continuation }
                }
            }
            switch reply {
            case .failure(let code):
                throw URLError(code)
            case .status(let code):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                               headerFields: nil)!
                return (Data(), response)
            }
        })
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var isHeld: Bool { lock.withLock { gate != nil } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds = false
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

private func jsonBody(_ request: URLRequest) throws -> [String: String] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
}

private let sampleDetails = "OpenSuperWhisper 0.14.0 (63) · macOS 26.2 · Apple Silicon · Parakeet Ultra"

/// The request the Feedback card posts: the website's endpoint and shape, with everything the
/// API does not know about folded into `context`.
final class FeedbackSenderTests: XCTestCase {

    func testItPostsJSONToTheFeedbackAPI() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .idea, message: "Hi", email: "", details: nil))

        XCTAssertEqual(request.url?.absoluteString, "https://git.my-monkey.fr/api/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testABugWithAnEmailAndTheDetails() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .bug, message: "  The bubble stays on screen.\n", email: " camille@example.com ",
            details: sampleDetails))

        XCTAssertEqual(try jsonBody(request), [
            "message": "The bubble stays on screen.",
            "email": "camille@example.com",
            "product": "opensuperwhisper",
            "context": "app · bug · " + sampleDetails,
        ])
    }

    func testAnIdeaWithoutEmailOrDetailsSendsNeither() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .idea, message: "Dark icon please", email: "   ", details: nil))

        let body = try jsonBody(request)
        XCTAssertEqual(body, [
            "message": "Dark icon please",
            "product": "opensuperwhisper",
            "context": "app · idea",
        ])
        XCTAssertNil(body["email"], "an empty email is left out, as the website does")
    }

    func testA2xxAnswerIsASuccess() async throws {
        let stub = FeedbackTransportStub(reply: .status(201))
        try await stub.sender.send(FeedbackSubmission(kind: .idea, message: "Hi", email: "", details: nil))
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testAnErrorStatusIsAFailure() async {
        let stub = FeedbackTransportStub(reply: .status(500))
        do {
            try await stub.sender.send(FeedbackSubmission(kind: .idea, message: "Hi", email: "", details: nil))
            XCTFail("a 500 was taken for a success")
        } catch {}
    }

    func testANetworkErrorIsAFailure() async {
        let stub = FeedbackTransportStub(reply: .failure(.notConnectedToInternet))
        do {
            try await stub.sender.send(FeedbackSubmission(kind: .idea, message: "Hi", email: "", details: nil))
            XCTFail("an offline send was taken for a success")
        } catch {}
    }
}

/// The details line, shown to the user word for word before it is sent.
final class FeedbackAppDetailsTests: XCTestCase {

    func testTheLineNamesVersionSystemChipAndModel() {
        XCTAssertEqual(FeedbackAppDetails.line(
            version: "0.14.0", build: "63",
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0),
            appleSilicon: true, model: "Parakeet Ultra"), sampleDetails)
    }

    func testAPatchReleaseAndNoModel() {
        XCTAssertEqual(FeedbackAppDetails.line(
            version: "0.14.0", build: "63",
            os: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
            appleSilicon: false, model: nil),
            "OpenSuperWhisper 0.14.0 (63) · macOS 15.6.1 · Intel")
    }
}

/// The card's draft and status: when Send is allowed, what a success and a failure leave behind.
@MainActor
final class FeedbackFormModelTests: XCTestCase {

    private func makeModel(_ stub: FeedbackTransportStub) -> FeedbackFormModel {
        FeedbackFormModel(sender: stub.sender, appDetails: { sampleDetails })
    }

    func testItStartsAsAnIdeaWithTheDetailsOn() {
        let model = makeModel(FeedbackTransportStub())
        XCTAssertEqual(model.kind, .idea)
        XCTAssertTrue(model.includeDetails)
        XCTAssertEqual(model.status, .editing)
        XCTAssertFalse(model.canSend)
    }

    func testSendNeedsTwoCharactersBesidesSpaces() {
        let model = makeModel(FeedbackTransportStub())
        for text in ["a", " a ", "\n\n a\t"] {
            model.message = text
            XCTAssertFalse(model.canSend, "\(text.debugDescription) was enough to send")
        }
        for text in ["ok", "a b"] {
            model.message = text
            XCTAssertTrue(model.canSend, "\(text.debugDescription) was not enough to send")
        }
    }

    func testTheSwitchDecidesWhetherTheDetailsGo() {
        let model = makeModel(FeedbackTransportStub())
        model.kind = .bug
        XCTAssertEqual(model.submission.context, "app · bug · " + sampleDetails)
        model.includeDetails = false
        XCTAssertEqual(model.submission.context, "app · bug")
    }

    func testASuccessThanksAndClearsTheForm() async throws {
        let stub = FeedbackTransportStub()
        let model = makeModel(stub)
        model.kind = .bug
        model.message = "It crashed"
        model.email = "camille@example.com"
        model.includeDetails = false

        await model.send()

        XCTAssertEqual(model.status, .sent)
        XCTAssertEqual(try jsonBody(XCTUnwrap(stub.requests.first))["message"], "It crashed")
        XCTAssertEqual(model.kind, .idea)
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(model.email, "")
        XCTAssertTrue(model.includeDetails)

        model.cardClosed()
        XCTAssertEqual(model.status, .editing, "the thank-you showed again on the next open")
    }

    func testAFailureKeepsTheText() async {
        let model = makeModel(FeedbackTransportStub(reply: .failure(.timedOut)))
        model.kind = .bug
        model.message = "It crashed"
        model.email = "camille@example.com"

        await model.send()

        XCTAssertEqual(model.status, .failed)
        XCTAssertEqual(model.kind, .bug)
        XCTAssertEqual(model.message, "It crashed")
        XCTAssertEqual(model.email, "camille@example.com")
        XCTAssertTrue(model.canSend, "a failed send could not be retried")
    }

    func testSendIsOffWhileSending() async {
        let stub = FeedbackTransportStub(holds: true)
        let model = makeModel(stub)
        model.message = "Hello there"

        let sending = Task { await model.send() }
        while !stub.isHeld { await Task.yield() }
        XCTAssertEqual(model.status, .sending)
        XCTAssertFalse(model.canSend)
        model.cardClosed()
        XCTAssertEqual(model.status, .sending, "closing the card forgot a send in flight")

        stub.release()
        await sending.value
        XCTAssertEqual(model.status, .sent)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testCancelDropsTheDraftButClosingKeepsIt() {
        let model = makeModel(FeedbackTransportStub())
        model.message = "Half a thought"
        model.cardClosed()
        XCTAssertEqual(model.message, "Half a thought", "a click outside the card lost the draft")
        model.discard()
        XCTAssertEqual(model.message, "")
    }
}
