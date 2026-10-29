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

/// Handles persistence of OpenTelemetry sessions to UserDefaults
/// Provides static methods for saving and loading session data
class AwsSessionStore {
  /// UserDefaults key for storing session ID
  static let idKey = "aws-rum-session-id"
  /// UserDefaults key for storing previous session ID
  static let previousIdKey = "aws-rum-session-previous-id"
  /// UserDefaults key for storing session expiry timestamp
  static let expireTimeKey = "aws-rum-session-expire-time"
  /// UserDefaults key for storing session start time
  static let startTimeKey = "aws-rum-session-start-time"
  /// UserDefaults key for storing session timeout
  static let sessionTimeoutKey = "aws-rum-session-timeout"

  // To avoid writing to disk too often, SessionStore only keeps the current session
  // in memory and saves to disk on an interval (every 30 seconds).

  /// Guards the static state below. Saves are scheduled from whichever thread refreshes
  /// the session, while the timer fires on `saveQueue`. It is never held while writing to
  /// UserDefaults: defaults observers run synchronously and may call back into the session
  /// manager, which can be in the middle of scheduling a save.
  private static let lock = NSLock()
  /// The most recent session to be saved to disk
  private static var pendingSession: AwsSession?
  /// The sequence number `pendingSession` was scheduled with, if any
  private static var pendingSequence: UInt64?
  /// The previous session
  private static var prevSession: AwsSession?
  /// The interval period after which the current session is saved to disk
  private static let saveInterval: TimeInterval = 30 // in seconds
  /// The timer responsible for saving the current session to disk. A dispatch timer,
  /// because a `Timer` scheduled from a thread without a running run loop never fires.
  private static var saveTimer: DispatchSourceTimer?
  /// The queue the save timer fires on
  private static let saveQueue = DispatchQueue(label: "software.amazon.opentelemetry.SessionStore", qos: .utility)
  /// The last sequence number handed out by `nextSaveSequence()`
  private static var lastIssuedSequence: UInt64 = 0
  /// The highest sequence number accepted by `scheduleSave`, so a save that arrives late
  /// can't replace a newer session
  private static var lastScheduledSequence: UInt64 = 0
  /// The highest sequence number written to UserDefaults. A write with a lower number is
  /// dropped, so a save that stalls before writing can't replace a newer session on disk.
  private static var lastWrittenSequence: UInt64 = 0

  /// A session waiting to be written, with the sequence number it was scheduled with
  private struct PendingWrite {
    let session: AwsSession
    let sequence: UInt64?
  }

  /// The next session to write, picked up by whichever thread is currently writing
  private static var nextWrite: PendingWrite?
  /// Whether a thread is writing to UserDefaults. Only one writes at a time, so the keys of
  /// two sessions never interleave and the last requested session is the one left on disk.
  private static var isWriting = false

  /// Returns an increasing sequence number to pass to `scheduleSave(session:sequence:)`.
  /// Take it while the session is changed, so saves keep that order even if they run later.
  static func nextSaveSequence() -> UInt64 {
    return lock.withLock {
      lastIssuedSequence += 1
      return lastIssuedSequence
    }
  }

  /// Schedules a session to be saved to UserDefaults on the next timer interval
  /// - Parameters:
  ///   - session: The session to save
  ///   - sequence: From `nextSaveSequence()`. A save with a lower number than one already
  ///     scheduled is ignored. Pass nil to schedule unconditionally.
  static func scheduleSave(session: AwsSession, sequence: UInt64? = nil) {
    let saveNow: Bool = lock.withLock {
      if let sequence {
        guard sequence > lastScheduledSequence else {
          return false
        }
        lastScheduledSequence = sequence
      }
      pendingSession = session
      pendingSequence = sequence

      guard saveTimer == nil else {
        return false
      }

      // save future sessions on a interval
      let timer = DispatchSource.makeTimerSource(queue: saveQueue)
      timer.schedule(deadline: .now() + saveInterval, repeating: saveInterval)
      timer.setEventHandler {
        // only write to disk if it is a new sesssion
        let pending: PendingWrite? = lock.withLock {
          guard let pending = pendingSession, prevSession != pending else {
            return nil
          }
          return PendingWrite(session: pending, sequence: pendingSequence)
        }
        if let pending {
          save(pending)
        }
      }
      timer.resume()
      saveTimer = timer
      return true
    }

    // save initial session
    if saveNow {
      save(PendingWrite(session: session, sequence: sequence))
    }
  }

  /// Immediately saves a session to UserDefaults
  /// - Parameter session: The session to save
  static func saveImmediately(session: AwsSession) {
    save(PendingWrite(session: session, sequence: nil))
  }

  /// Writes a session to UserDefaults without holding `lock`. If another thread is already
  /// writing, it writes this session once it finishes, and this call returns straight away.
  /// A sequenced write older than one already written or queued is dropped; an unsequenced
  /// write is always made.
  static func save(session: AwsSession, sequence: UInt64?) {
    save(PendingWrite(session: session, sequence: sequence))
  }

  private static func save(_ request: PendingWrite) {
    let isWriter: Bool = lock.withLock {
      if let sequence = request.sequence {
        guard sequence > lastWrittenSequence else {
          return false
        }
        if let queued = nextWrite?.sequence, sequence < queued {
          return false
        }
      }
      nextWrite = request
      guard !isWriting else {
        return false
      }
      isWriting = true
      return true
    }
    guard isWriter else {
      return
    }

    // Only this thread writes until `takeNextWrite()` ends its turn, so nothing newer can
    // reach the disk between taking a write and making it
    while let next = takeNextWrite() {
      write(session: next.session)
      lock.withLock {
        if let sequence = next.sequence {
          lastWrittenSequence = max(lastWrittenSequence, sequence)
        }
        // update prev session
        prevSession = next.session
        // clear pending session, since it is now outdated, unless a newer one arrived
        if pendingSession == next.session {
          pendingSession = nil
          pendingSequence = nil
        }
      }
    }
  }

  /// Takes the next write, or ends this thread's turn as writer if there is none
  private static func takeNextWrite() -> PendingWrite? {
    return lock.withLock {
      guard let next = nextWrite else {
        isWriting = false
        return nil
      }
      nextWrite = nil
      return next
    }
  }

  /// Persists a session to UserDefaults. Must be called without `lock` held.
  private static func write(session: AwsSession) {
    AwsInternalLogger.debug("Saving session to UserDefaults: \(session.id)")

    // Persist session
    UserDefaults.standard.set(session.id, forKey: idKey)
    UserDefaults.standard.set(session.expireTime, forKey: expireTimeKey)
    UserDefaults.standard.set(session.startTime, forKey: startTimeKey)
    UserDefaults.standard.set(session.previousId, forKey: previousIdKey)
    UserDefaults.standard.set(session.sessionTimeout, forKey: sessionTimeoutKey)
  }

  /// Loads a previously saved session from UserDefaults
  /// - Returns: The saved session if ID, startTime, and expireTime exist. nil otherwise
  static func load() -> AwsSession? {
    return lock.withLock {
      guard let startTime = UserDefaults.standard.object(forKey: startTimeKey) as? Date,
            let id = UserDefaults.standard.string(forKey: idKey),
            let expireTime = UserDefaults.standard.object(forKey: expireTimeKey) as? Date,
            let sessionTimeout = UserDefaults.standard.object(forKey: sessionTimeoutKey) as? Int
      else {
        AwsInternalLogger.debug("No valid session found in UserDefaults")
        return nil
      }

      let previousId = UserDefaults.standard.string(forKey: previousIdKey)
      AwsInternalLogger.debug("Found session in UserDefaults: \(id), previous: \(previousId ?? "none")")

      // reset sessions so it does not get overridden in the next scheduled save
      pendingSession = nil
      pendingSequence = nil
      prevSession = AwsSession(
        id: id,
        expireTime: expireTime,
        previousId: previousId,
        startTime: startTime,
        sessionTimeout: sessionTimeout
      )
      return prevSession
    }
  }

  /// Cleans up timer and UserDefaults
  static func teardown() {
    AwsInternalLogger.info("Tearing down AwsSessionStore")
    lock.withLock {
      saveTimer?.cancel()
      saveTimer = nil
      pendingSession = nil
      pendingSequence = nil
      prevSession = nil
      nextWrite = nil
      lastScheduledSequence = 0
      lastWrittenSequence = 0
    }
    UserDefaults.standard.removeObject(forKey: idKey)
    UserDefaults.standard.removeObject(forKey: startTimeKey)
    UserDefaults.standard.removeObject(forKey: expireTimeKey)
    UserDefaults.standard.removeObject(forKey: previousIdKey)
    UserDefaults.standard.removeObject(forKey: sessionTimeoutKey)
    AwsInternalLogger.debug("AwsSessionStore teardown complete")
  }
}
