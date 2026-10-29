# Changelog

All notable changes to this project will be documented in this file.

> **Note:** This CHANGELOG was created starting from version 1.0.0. Earlier changes are not documented here.

## Unreleased

### Fixed
- Make session tracking thread-safe. `AwsSessionManager` now checks for, starts and extends a session in one locked step; `AwsSessionEventInstrumentation` locks its event queue and `isApplied` flag; and `AwsSessionStore` locks its state and saves on a dispatch timer, which also fires when the first save happens off the main thread. Fixes a crash in `AwsSessionEventInstrumentation.addSession` when several URLSession requests start while the SDK is initializing. UserDefaults writes, session events and the session start notification all happen outside the locks, because they can call back into the session manager. Saves keep the order the session changed in, and session starts are published in the order they happened, so observers such as KSCrash end on the current session.

## v1.1.0 - 2026-08-19

### Removed
- Removed `static-code-checks` job (CHANGELOG enforcement) from Build and Test workflow — it was broken on push events and caused spurious CI failures ([#103](https://github.com/aws-observability/aws-otel-swift/pull/108))

### Fixed
- Pin `opentelemetry-swift-core`, `opentelemetry-swift`, `aws-sdk-swift`, and `smithy-swift` to exact versions to prevent SPM from resolving to incompatible newer releases ([#103](https://github.com/aws-observability/aws-otel-swift/pull/103))


