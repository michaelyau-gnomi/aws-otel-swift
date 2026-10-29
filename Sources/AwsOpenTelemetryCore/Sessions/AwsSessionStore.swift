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

  /// Guards `pendingSession`, `prevSession` and `saveTimer`. Saves are scheduled from
  /// whichever thread refreshes the session, while the timer fires on `saveQueue`.
  private static let lock = NSLock()
  /// The most recent session to be saved to disk
  private static var pendingSession: AwsSession?
  /// The previous session
  private static var prevSession: AwsSession?
  /// The interval period after which the current session is saved to disk
  private static let saveInterval: TimeInterval = 30 // in seconds
  /// The timer responsible for saving the current session to disk. A dispatch timer,
  /// because a `Timer` scheduled from a thread without a running run loop never fires.
  private static var saveTimer: DispatchSourceTimer?
  /// The queue the save timer fires on
  private static let saveQueue = DispatchQueue(label: "software.amazon.opentelemetry.SessionStore", qos: .utility)

  /// Schedules a session to be saved to UserDefaults on the next timer interval
  /// - Parameter session: The session to save
  static func scheduleSave(session: AwsSession) {
    lock.withLock {
      pendingSession = session

      if saveTimer == nil {
        // save initial session
        save(session: session)

        // save future sessions on a interval
        let timer = DispatchSource.makeTimerSource(queue: saveQueue)
        timer.schedule(deadline: .now() + saveInterval, repeating: saveInterval)
        timer.setEventHandler {
          lock.withLock {
            // only write to disk if it is a new sesssion
            if let pending = pendingSession, prevSession != pending {
              save(session: pending)
            }
          }
        }
        timer.resume()
        saveTimer = timer
      }
    }
  }

  /// Immediately saves a session to UserDefaults
  /// - Parameter session: The session to save
  static func saveImmediately(session: AwsSession) {
    lock.withLock { save(session: session) }
  }

  /// Saves a session to UserDefaults. Must be called with `lock` held.
  private static func save(session: AwsSession) {
    AwsInternalLogger.debug("Saving session to UserDefaults: \(session.id)")

    // Persist session
    UserDefaults.standard.set(session.id, forKey: idKey)
    UserDefaults.standard.set(session.expireTime, forKey: expireTimeKey)
    UserDefaults.standard.set(session.startTime, forKey: startTimeKey)
    UserDefaults.standard.set(session.previousId, forKey: previousIdKey)
    UserDefaults.standard.set(session.sessionTimeout, forKey: sessionTimeoutKey)

    // update prev session
    prevSession = session
    // clear pending session, since it is now outdated
    pendingSession = nil
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
      prevSession = nil
      UserDefaults.standard.removeObject(forKey: idKey)
      UserDefaults.standard.removeObject(forKey: startTimeKey)
      UserDefaults.standard.removeObject(forKey: expireTimeKey)
      UserDefaults.standard.removeObject(forKey: previousIdKey)
      UserDefaults.standard.removeObject(forKey: sessionTimeoutKey)
    }
    AwsInternalLogger.debug("AwsSessionStore teardown complete")
  }
}
