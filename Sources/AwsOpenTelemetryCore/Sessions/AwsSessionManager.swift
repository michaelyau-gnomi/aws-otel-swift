/*
 * Copyright Amazon.com, Inc. or its affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

import Foundation

/// Manages OpenTelemetry sessions with automatic expiration and persistence.
/// Provides thread-safe access to session information and handles session lifecycle.
/// Sessions are automatically extended on access and persisted to UserDefaults.
public class AwsSessionManager {
  private var configuration: AwsSessionConfig

  /// Guards the state below, so checking for an expired session and replacing it happen
  /// as one step even when spans start on several threads at once. Saving to disk, session
  /// events and the start notification all happen after it is released, because they can
  /// call back into this manager: a `session.start` log record passes through
  /// `AwsSessionLogProcessor`, which calls `getSession()`, and UserDefaults observers run
  /// synchronously.
  private let lock = NSLock()
  private var _session: AwsSession?
  private var _isSessionSampled: Bool = true
  /// Started sessions waiting to be published, oldest first
  private var pendingPublications: [SessionRefresh] = []
  /// Whether a thread is publishing `pendingPublications`. Only one publishes at a time, so
  /// observers see sessions in the order they started and the last one they see is current.
  private var isPublishing = false

  /// Initializes the session manager and restores any previous session from disk
  /// - Parameter configuration: Session configuration settings
  public init(configuration: AwsSessionConfig = .default) {
    self.configuration = configuration
    restoreSessionFromDisk()
  }

  /// Gets the current session, creating or extending it as needed
  /// This method is thread-safe and will extend the session expireTime time
  /// - Returns: The current active session
  @discardableResult
  public func getSession() -> AwsSession {
    let (refresh, shouldPublish): (SessionRefresh, Bool) = lock.withLock {
      let refresh = refreshSession()
      if refresh.isNew {
        pendingPublications.append(refresh)
      }
      // If another thread is publishing, it publishes this session after its own
      guard !isPublishing, !pendingPublications.isEmpty else {
        return (refresh, false)
      }
      isPublishing = true
      return (refresh, true)
    }

    AwsSessionStore.scheduleSave(session: refresh.session, sequence: refresh.saveSequence)
    if shouldPublish {
      publishPendingSessions()
    }
    return refresh.session
  }

  /// Gets the current session without extending its expireTime time
  /// - Returns: The current session if one exists, nil otherwise
  public func peekSession() -> AwsSession? {
    return lock.withLock { _session }
  }

  /// Gets whether the current session is sampled
  public var isSessionSampled: Bool {
    return lock.withLock { _isSessionSampled }
  }

  /// Determines if a session should be sampled based on the sample rate
  /// - Parameter sampleRate: Sample rate from 0.0 to 1.0
  /// - Returns: True if session should be sampled, false otherwise
  private func shouldSampleSession(sampleRate: Double) -> Bool {
    return Double.random(in: 0.01 ... 1) <= sampleRate
  }

  /// The outcome of a refresh, carried out of the lock so its side effects can run unlocked
  private struct SessionRefresh {
    let session: AwsSession
    let isNew: Bool
    let previousSession: AwsSession?
    /// Keeps saves in the order the session changed, though they run after `lock` is released
    let saveSequence: UInt64
  }

  /// Creates a new session with a unique identifier. Must be called with `lock` held.
  private func startSession() -> SessionRefresh {
    let now = Date()
    let previousSession = _session
    let previousId = previousSession?.id
    let newId = UUID().uuidString

    // Update session sampling based on RNG
    _isSessionSampled = shouldSampleSession(sampleRate: configuration.sessionSampleRate)

    AwsInternalLogger.info("Creating new session: \(newId), previous: \(previousId ?? "none")")

    if !_isSessionSampled {
      AwsInternalLogger.debug("Session \(newId) will NOT be sampled")
    } else {
      AwsInternalLogger.debug("Session \(newId) will be sampled")
    }

    let session = AwsSession(
      id: newId,
      expireTime: now.addingTimeInterval(Double(configuration.sessionTimeout)),
      previousId: previousId,
      startTime: now,
      sessionTimeout: configuration.sessionTimeout
    )
    _session = session
    return SessionRefresh(
      session: session,
      isNew: true,
      previousSession: previousSession,
      saveSequence: AwsSessionStore.nextSaveSequence()
    )
  }

  /// Refreshes the current session, creating new one if expired or extending existing one.
  /// Must be called with `lock` held.
  private func refreshSession() -> SessionRefresh {
    let refresh: SessionRefresh
    if let current = _session, !current.isExpired() {
      // Otherwise, extend the existing session but preserve the startTime
      let extended = AwsSession(
        id: current.id,
        expireTime: Date(timeIntervalSinceNow: Double(configuration.sessionTimeout)),
        previousId: current.previousId,
        startTime: current.startTime,
        sessionTimeout: configuration.sessionTimeout
      )
      _session = extended
      refresh = SessionRefresh(
        session: extended,
        isNew: false,
        previousSession: nil,
        saveSequence: AwsSessionStore.nextSaveSequence()
      )
    } else {
      refresh = startSession()
    }
    return refresh
  }

  /// Publishes started sessions in the order they started, until none are left.
  /// Must be called without `lock` held, by the thread that set `isPublishing`.
  private func publishPendingSessions() {
    while let next = takeNextPublication() {
      publishSessionStart(next.session, previousSession: next.previousSession)
    }
  }

  /// Takes the oldest unpublished session, or ends this thread's turn as publisher if none
  private func takeNextPublication() -> SessionRefresh? {
    return lock.withLock {
      guard !pendingPublications.isEmpty else {
        isPublishing = false
        return nil
      }
      return pendingPublications.removeFirst()
    }
  }

  /// Sends the `session.end` and `session.start` events and the start notification.
  /// Must be called without `lock` held.
  private func publishSessionStart(_ session: AwsSession, previousSession: AwsSession?) {
    // Queue the previous session for a `session.end` event
    if let previousSession {
      AwsSessionEventInstrumentation.addSession(session: previousSession, eventType: .end)
    }

    // Queue the new session for a `session.start`` event
    AwsSessionEventInstrumentation.addSession(session: session, eventType: .start)

    // Post notification for session start
    NotificationCenter.default.post(name: SessionStartNotification, object: session)
  }

  /// Restores a previously saved session from UserDefaults
  private func restoreSessionFromDisk() {
    let restored = AwsSessionStore.load()
    lock.withLock { _session = restored }
  }
}
