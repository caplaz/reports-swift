import Foundation
// SPI from the 9.24.0 binary's .private.swiftinterface (exact pin; re-verify on every bump):
// SentryEnvelope.items, SentryEnvelopeItem.type(), SentryEnvelopeItemTypes.traceMetric.
@_spi(Private) import Sentry

extension CrashReporting {
    /// Opt-out step (spec §4.2). On the main thread, inside the consent transition, after the
    /// gate closed.
    static func revokePendingMetrics(_ configuration: CrashReportingConfiguration?) {
        // Before deleting anything, so the next start sweeps even if this one is interrupted.
        CrashReportingPreference.setPendingMetricSweep(true, in: preferenceDefaults)
        metricRevocation.revoke()
        // Serial queue: every emission queued or running finishes first. Those starting now see
        // the closed gate and drop; each metric that already passed `beforeSendMetric` is now
        // enqueued in the SDK buffer.
        metricQueue.sync {}
        forwardMetricBuffer()
        // A failure leaves the gate closed; re-enable sweeps again and fails closed.
        if let configuration { _ = deleteMetricEnvelopes(in: configuration.cacheDirectory) }
    }

    /// Re-enable step, before the consent marker is removed and the gate reopens. `false` when
    /// a metric envelope could not be deleted: the caller keeps reporting off (fail closed).
    static func reopenMetrics(_ configuration: CrashReportingConfiguration) -> Bool {
        forwardMetricBuffer()
        guard deleteMetricEnvelopes(in: configuration.cacheDirectory) else { return false }
        metricRevocation.reopen()
        return true
    }

    /// Hands the SDK's metric (and log) batch to the transport synchronously before waiting
    /// (`SentryClient.m:673-682`, `TelemetryBuffer.swift:76-83`). A pre-cutoff metric batch
    /// sent here hits the wire check first and gets a synthetic 200, so the transport deletes
    /// it unsent (`SentryHttpTransport.m:433-447`) without the closed gate ever being
    /// consulted; other envelope types (not metrics) do reach the gate, which is closed, so
    /// their send attempts are refused and the files stay. The wait is bounded and not needed
    /// for correctness (spec §2.5.2); `deleteMetricEnvelopes` right after sweeps up anything
    /// this didn't reach.
    private static func forwardMetricBuffer() {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.flush(timeout: 1)
    }

    /// Deletes every queued envelope holding a `trace_metric` item from each
    /// `io.sentry/<DSN hash>/envelopes/` under `cacheDirectory` (`SentryFileManagerHelper.m:14,145-192`).
    /// Fails closed (spec §4.2 "Sweep"): `true` only when every envelope was inspected and every
    /// metric envelope is gone.
    /// - Absent (`io.sentry`, a DSN directory without `envelopes`, a file deleted between listing
    ///   and reading): nothing to delete, success.
    /// - A listing or `isDirectory` error, or an envelope file that can't be read: failure. The
    ///   sweep can't tell what that file holds.
    /// - A file the SDK can't deserialize is removed. The transport deletes such files unsent
    ///   (`SentryHttpTransport.m:331-337`), and the SDK writes envelopes atomically
    ///   (`SentryFileManagerHelper.m:592-599`), so nothing deliverable is lost.
    /// - A failed removal: failure (`remove` counts absence as success).
    /// The sweep keeps going after a failure, deleting what it can.
    static func deleteMetricEnvelopes(in cacheDirectory: URL) -> Bool {
        var complete = true
        let base = cacheDirectory.appendingPathComponent("io.sentry", isDirectory: true)
        for dsnDirectory in contents(of: base, complete: &complete) {
            let isDirectory: Bool
            do {
                isDirectory = try dsnDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                complete = false
                continue
            }
            guard isDirectory else { continue }
            let envelopes = dsnDirectory.appendingPathComponent("envelopes", isDirectory: true)
            for file in contents(of: envelopes, complete: &complete) {
                let data: Data
                do {
                    data = try readFile(file)
                } catch let error where isNoSuchFile(error) {
                    continue   // deleted since it was listed
                } catch {
                    complete = false   // unreadable: it may hold a metric
                    continue
                }
                if let envelope = PrivateSentrySDKOnly.envelope(with: data),
                   !envelope.items.contains(where: { $0.type() == SentryEnvelopeItemTypes.traceMetric }) {
                    continue   // readable, holds no metric: kept
                }
                if !remove(file) { complete = false }
            }
        }
        return complete
    }

    /// `directory`'s entries; `[]` when it doesn't exist; `[]` and `complete = false` on any
    /// other listing error.
    private static func contents(of directory: URL, complete: inout Bool) -> [URL] {
        do {
            return try listDirectory(directory)
        } catch let error where isNoSuchFile(error) {
            return []
        } catch {
            complete = false
            return []
        }
    }

    /// "No such file", in Cocoa (`NSFileNoSuchFileError`, `NSFileReadNoSuchFileError`) or POSIX
    /// (`ENOENT`) form, also as the underlying error.
    static func isNoSuchFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue || error.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { isNoSuchFile($0) } ?? false
    }

    /// Listing and reading seams for failure-injection tests (spec §4.2 "Sweep"); production
    /// always uses `FileManager` and `Data(contentsOf:)`. Restored by `resetFileSeamsForTesting`.
    nonisolated(unsafe) static var listDirectory: (URL) throws -> [URL] = defaultListDirectory
    nonisolated(unsafe) static var readFile: (URL) throws -> Data = defaultReadFile

    private static func defaultListDirectory(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
    }

    private static func defaultReadFile(_ file: URL) throws -> Data { try Data(contentsOf: file) }

    /// Test-only: production file access for `removeItem`, `listDirectory` and `readFile`.
    static func resetFileSeamsForTesting() {
        removeItem = { try FileManager.default.removeItem(at: $0) }
        listDirectory = defaultListDirectory
        readFile = defaultReadFile
    }
}
