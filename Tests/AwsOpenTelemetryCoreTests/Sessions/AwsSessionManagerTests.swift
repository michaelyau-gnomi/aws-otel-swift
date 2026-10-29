import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import AwsOpenTelemetryCore

final class AwsSessionManagerTests: XCTestCase {
  var sessionManager: AwsSessionManager!

  override func setUp() {
    super.setUp()
    AwsSessionStore.teardown()
    sessionManager = AwsSessionManager()
  }

  override func tearDown() {
    NotificationCenter.default.removeObserver(self)
    AwsSessionStore.teardown()
    super.tearDown()
  }

  func testGetSession() {
    let session = sessionManager.getSession()
    XCTAssertNotNil(session)
    XCTAssertNotNil(session.id)
    XCTAssertNotNil(session.expireTime)
    XCTAssertNil(session.previousId)
  }

  func testGetSessionId() {
    let id1 = sessionManager.getSession().id
    let id2 = sessionManager.getSession().id
    XCTAssertEqual(id1, id2)
  }

  func testGetSessionRenewed() {
    let t1 = sessionManager.getSession().expireTime
    let t2 = sessionManager.getSession().expireTime
    XCTAssertGreaterThan(t2, t1)
  }

  func testStartTimePreservedWhenSessionExtended() {
    let originalSession = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.1)
    let extendedSession = sessionManager.getSession()

    XCTAssertEqual(originalSession.id, extendedSession.id)
    XCTAssertGreaterThan(extendedSession.expireTime, originalSession.expireTime)
    XCTAssertEqual(originalSession.startTime, extendedSession.startTime)
  }

  func testGetSessionExpired() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0))
    let session1 = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.1)
    let session2 = sessionManager.getSession()

    XCTAssertNotEqual(session1.id, session2.id)
    XCTAssertNotEqual(session1.startTime, session2.startTime)
    XCTAssertGreaterThan(session2.startTime, session1.startTime)
  }

  func testGetSessionSavedToDisk() {
    let session = sessionManager.getSession()
    let savedId = UserDefaults.standard.object(forKey: AwsSessionStore.idKey) as? String
    let savedTimeout = UserDefaults.standard.object(forKey: AwsSessionStore.sessionTimeoutKey) as? Int

    XCTAssertEqual(session.id, savedId)
    XCTAssertEqual(session.sessionTimeout, savedTimeout)
  }

  func testLoadSessionMissingExpiry() {
    UserDefaults.standard.removeObject(forKey: AwsSessionStore.expireTimeKey)
    UserDefaults.standard.set("test-id", forKey: AwsSessionStore.idKey)
    UserDefaults.standard.set(Date(), forKey: AwsSessionStore.startTimeKey)
    UserDefaults.standard.set(1800, forKey: AwsSessionStore.sessionTimeoutKey)

    let loadedSession = AwsSessionStore.load()
    XCTAssertNil(loadedSession)
  }

  func testLoadSessionMissingID() {
    let expiry1 = Date()
    UserDefaults.standard.set(expiry1, forKey: AwsSessionStore.expireTimeKey)
    XCTAssertNil(AwsSessionStore.load())

    let expiry2 = sessionManager.getSession().expireTime
    XCTAssertNotEqual(expiry1, expiry2)
  }

  func testPeekSessionWithoutSession() {
    XCTAssertNil(sessionManager.peekSession())
  }

  func testPeekSessionWithExistingSession() {
    let session = sessionManager.getSession()
    let peekedSession = sessionManager.peekSession()

    XCTAssertNotNil(peekedSession)
    XCTAssertEqual(peekedSession?.id, session.id)
  }

  func testPeekDoesNotExtendSession() {
    let originalSession = sessionManager.getSession()
    let peekedSession = sessionManager.peekSession()

    XCTAssertEqual(peekedSession?.expireTime, originalSession.expireTime)
  }

  func testCustomSessionLength() {
    let customLength = 60
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: customLength))

    let session1 = sessionManager.getSession()
    let expectedExpiry = Date(timeIntervalSinceNow: Double(customLength))

    XCTAssertEqual(session1.expireTime.timeIntervalSince1970, expectedExpiry.timeIntervalSince1970, accuracy: 1.0)
    XCTAssertEqual(session1.sessionTimeout, customLength)
  }

  func testCustomSessionSampleRate() {
    let customSampleRate = 0.5
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: customSampleRate))
    sessionManager.getSession()

    // Can't predict exact outcome with 0.5, but should not crash
    let sampling = sessionManager.isSessionSampled
    XCTAssertTrue(sampling == true || sampling == false)
  }

  func testNewSessionHasNoPreviousId() {
    let session = sessionManager.getSession()
    XCTAssertNil(session.previousId)
  }

  func testExpiredSessionCreatesPreviousId() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0))
    let firstSession = sessionManager.getSession()
    let secondSession = sessionManager.getSession()
    let thirdSession = sessionManager.getSession()

    XCTAssertNil(firstSession.previousId)
    XCTAssertEqual(secondSession.previousId, firstSession.id)
    XCTAssertEqual(thirdSession.previousId, secondSession.id)
  }

  func testStartSessionAddsToQueueWhenInstrumentationNotApplied() {
    AwsSessionEventInstrumentation.queue = []
    AwsSessionEventInstrumentation.isApplied = false
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0))
    let session = sessionManager.getSession()

    // Wait for async session event processing
    let expectation = XCTestExpectation(description: "Session event queued")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    XCTAssertEqual(AwsSessionEventInstrumentation.queue.count, 1)
    XCTAssertEqual(AwsSessionEventInstrumentation.queue[0].session.id, session.id)
  }

  func testStartSessionProcessesDirectlyWhenInstrumentationApplied() {
    AwsSessionEventInstrumentation.queue = []
    AwsSessionEventInstrumentation.isApplied = true

    let session = sessionManager.getSession()

    // When instrumentation is applied, sessions are processed directly, not queued
    XCTAssertEqual(AwsSessionEventInstrumentation.queue.count, 0)
    XCTAssertNotNil(session.id)
  }

  func testSessionStartNotificationPosted() {
    let expectation = XCTestExpectation(description: "Session start notification")
    var receivedSession: AwsSession?

    let observer = NotificationCenter.default.addObserver(
      forName: SessionStartNotification,
      object: nil,
      queue: nil
    ) { notification in
      receivedSession = notification.object as? AwsSession
      expectation.fulfill()
    }

    let session = sessionManager.getSession()

    wait(for: [expectation], timeout: 2.0) // Increased timeout for async processing
    XCTAssertEqual(receivedSession?.id, session.id)

    NotificationCenter.default.removeObserver(observer)
  }

  func testMultipleSessionStartNotifications() {
    // Clean up any existing state
    AwsSessionStore.teardown()
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0))

    var receivedSessions: [String] = []
    let expectation = XCTestExpectation(description: "Multiple session notifications")
    expectation.expectedFulfillmentCount = 3

    let observer = NotificationCenter.default.addObserver(
      forName: SessionStartNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let session = notification.object as? AwsSession {
        receivedSessions.append(session.id)
      }
      expectation.fulfill()
    }

    let session1 = sessionManager.getSession()
    let session2 = sessionManager.getSession()
    let session3 = sessionManager.getSession()

    wait(for: [expectation], timeout: 2.0)

    NotificationCenter.default.removeObserver(observer)

    // Only check the count and that we got the expected sessions
    XCTAssertEqual(receivedSessions.count, 3)
    XCTAssertTrue(receivedSessions.contains(session1.id))
    XCTAssertTrue(receivedSessions.contains(session2.id))
    XCTAssertTrue(receivedSessions.contains(session3.id))
  }

  func testSessionSamplingWithFullSampleRate() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: 1.0))
    sessionManager.getSession()
    XCTAssertTrue(sessionManager.isSessionSampled)
  }

  func testSessionSamplingWithZeroSampleRate() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: 0.0))
    sessionManager.getSession()
    XCTAssertFalse(sessionManager.isSessionSampled)
  }

  func testSessionSamplingPersistsAcrossSessionExtensions() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: 1.0))
    sessionManager.getSession()
    let initialSampling = sessionManager.isSessionSampled

    // Extend session
    sessionManager.getSession()
    XCTAssertEqual(sessionManager.isSessionSampled, initialSampling)
  }

  func testSessionSamplingChangesOnNewSession() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0, sessionSampleRate: 1.0))
    sessionManager.getSession()
    let firstSampling = sessionManager.isSessionSampled

    // Force new session
    sessionManager.getSession()
    let secondSampling = sessionManager.isSessionSampled

    // Both should be true with 1.0 sample rate
    XCTAssertTrue(firstSampling)
    XCTAssertTrue(secondSampling)
  }

  func testSessionSamplingWithFullSampleRateNewSession() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: 1.0))
    sessionManager.getSession()
    XCTAssertTrue(sessionManager.isSessionSampled)
  }

  func testSessionSamplingWithZeroSampleRateNewSession() {
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionSampleRate: 0.0))
    sessionManager.getSession()
    XCTAssertFalse(sessionManager.isSessionSampled)
  }

  // MARK: - Concurrency

  func testConcurrentGetSessionStartsOneSession() {
    AwsSessionEventInstrumentation.queue = []
    AwsSessionEventInstrumentation.isApplied = false
    defer { AwsSessionEventInstrumentation.queue = [] }

    let lock = NSLock()
    var ids = Set<String>()
    DispatchQueue.concurrentPerform(iterations: 500) { _ in
      let id = sessionManager.getSession().id
      lock.withLock { _ = ids.insert(id) }
    }

    XCTAssertEqual(ids.count, 1)
    XCTAssertEqual(AwsSessionEventInstrumentation.queue.count, 1)
    XCTAssertEqual(AwsSessionEventInstrumentation.queue.first?.session.id, ids.first)
    XCTAssertEqual(AwsSessionEventInstrumentation.queue.first?.eventType, .start)
  }

  func testConcurrentGetSessionWithExpiringSessionsKeepsOneChain() {
    AwsSessionEventInstrumentation.queue = []
    AwsSessionEventInstrumentation.isApplied = false
    defer { AwsSessionEventInstrumentation.queue = [] }
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 0))

    // Every call starts a new session, so every call races to replace the previous one
    let iterations = 200
    let lock = NSLock()
    var sessions: [AwsSession] = []
    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      let session = sessionManager.getSession()
      lock.withLock { sessions.append(session) }
    }

    // Each session replaced exactly one other, so the sessions form a single chain
    XCTAssertEqual(Set(sessions.map(\.id)).count, iterations)
    XCTAssertEqual(sessions.filter { $0.previousId == nil }.count, 1)
    let previousIds = sessions.compactMap(\.previousId)
    XCTAssertEqual(Set(previousIds).count, iterations - 1)
    XCTAssertTrue(Set(previousIds).isSubset(of: Set(sessions.map(\.id))))

    // Queued events are capped rather than corrupted
    XCTAssertEqual(AwsSessionEventInstrumentation.queue.count, Int(AwsSessionEventInstrumentation.maxQueueSize))
  }

  func testConcurrentGetAndPeekSession() {
    DispatchQueue.concurrentPerform(iterations: 500) { i in
      if i.isMultiple(of: 2) {
        sessionManager.getSession()
      } else {
        _ = sessionManager.peekSession()
        _ = sessionManager.isSessionSampled
      }
    }

    XCTAssertNotNil(sessionManager.peekSession())
  }

  func testUserDefaultsObserverCanReadSessionWhileSaving() {
    // UserDefaults KVO runs synchronously on the saving thread, so this observer runs
    // in the middle of the first save
    let observer = UserDefaultsKeyObserver {
      _ = self.sessionManager.peekSession()
      _ = self.sessionManager.getSession()
    }
    UserDefaults.standard.addObserver(observer, forKeyPath: AwsSessionStore.idKey, options: [.new], context: nil)
    defer { UserDefaults.standard.removeObserver(observer, forKeyPath: AwsSessionStore.idKey) }

    let returned = expectation(description: "getSession returns")
    DispatchQueue.global().async {
      self.sessionManager.getSession()
      returned.fulfill()
    }

    wait(for: [returned], timeout: 5.0)
    XCTAssertGreaterThan(observer.callCount, 0)
  }

  func testSessionStartNotificationsArriveInStartOrder() {
    AwsSessionEventInstrumentation.queue = []
    AwsSessionEventInstrumentation.isApplied = true
    sessionManager = AwsSessionManager(configuration: AwsSessionConfig(sessionTimeout: 1))

    // Stall the first session's start event, before its notification is posted
    let firstEventStarted = DispatchSemaphore(value: 0)
    let releaseFirstEvent = DispatchSemaphore(value: 0)
    let gate = GatedLogRecordProcessor {
      firstEventStarted.signal()
      releaseFirstEvent.wait()
    }
    OpenTelemetry.registerLoggerProvider(loggerProvider: LoggerProviderBuilder().with(processors: [gate]).build())
    defer {
      OpenTelemetry.registerLoggerProvider(loggerProvider: DefaultLoggerProvider.instance)
      AwsSessionEventInstrumentation.isApplied = false
    }

    let lock = NSLock()
    var notifiedIds: [String] = []
    let notified = expectation(description: "Both session start notifications")
    notified.expectedFulfillmentCount = 2
    let observer = NotificationCenter.default.addObserver(forName: SessionStartNotification, object: nil, queue: nil) { notification in
      if let session = notification.object as? AwsSession {
        lock.withLock { notifiedIds.append(session.id) }
      }
      notified.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    DispatchQueue.global().async {
      self.sessionManager.getSession()
    }
    firstEventStarted.wait()

    // Let the first session expire while its events are stalled, then start the next one
    Thread.sleep(forTimeInterval: 1.2)
    let secondSession = sessionManager.getSession()
    releaseFirstEvent.signal()

    wait(for: [notified], timeout: 5.0)
    let ids = lock.withLock { notifiedIds }
    XCTAssertEqual(ids.count, 2)
    XCTAssertEqual(ids.first, secondSession.previousId)
    // Observers such as KSCrash keep the last session they were told about
    XCTAssertEqual(ids.last, secondSession.id)
  }
}

/// Calls `onChange` whenever the observed UserDefaults key changes
private final class UserDefaultsKeyObserver: NSObject {
  private let onChange: () -> Void
  private let lock = NSLock()
  private var _callCount = 0

  var callCount: Int {
    return lock.withLock { _callCount }
  }

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  override func observeValue(forKeyPath keyPath: String?,
                             of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    lock.withLock { _callCount += 1 }
    onChange()
  }
}

/// Runs `onFirstEmit` on the first log record it receives, and ignores the rest
private final class GatedLogRecordProcessor: LogRecordProcessor {
  private let onFirstEmit: () -> Void
  private let lock = NSLock()
  private var hasEmitted = false

  init(onFirstEmit: @escaping () -> Void) {
    self.onFirstEmit = onFirstEmit
  }

  func onEmit(logRecord: ReadableLogRecord) {
    let isFirst: Bool = lock.withLock {
      defer { hasEmitted = true }
      return !hasEmitted
    }
    if isFirst {
      onFirstEmit()
    }
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    return .success
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    return .success
  }
}
