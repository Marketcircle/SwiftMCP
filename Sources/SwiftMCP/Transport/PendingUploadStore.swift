import Foundation

/// Tracks pending content-ID uploads for a session.
///
/// When a tool call contains `cid:` placeholders for Data parameters,
/// the server registers expectations here. The upload endpoint fulfills
/// them, resuming the tool call's parameter extraction.
///
/// Supports early-arrival uploads: if the binary POST arrives before the
/// tool call registers the CID expectation, the file is buffered and
/// returned immediately when `waitForUpload()` is called. An upload that
/// fails before the expectation is registered is kept the same way and
/// thrown when `waitForUpload()` is called.
actor PendingUploadStore {

    struct Expectation {
        let continuation: CheckedContinuation<URL, Error>
        let progressToken: JSONValue?
        let sessionID: UUID
    }

    struct EarlyArrival {
        let fileURL: URL
        let arrivedAt: Date
    }

    /// A failed upload whose tool call has not registered the CID yet.
    struct EarlyFailure {
        /// The error the upload ended with.
        let error: Error
        /// The time the failure arrived.
        let failedAt: Date
        /// The position of the failure among all early failures.
        let order: Int
    }

    /// The most early failures the store keeps at once.
    static let maxEarlyFailures = 64

    internal var expectations: [String: Expectation] = [:]  // cid → expectation
    internal var earlyArrivals: [String: EarlyArrival] = [:]  // cid → early arrival
    /// The early failures by CID.
    internal var earlyFailures: [String: EarlyFailure] = [:]
    /// The number of early failures recorded so far.
    private var failureCount = 0

    /// Register a pending upload. Returns when the file arrives or the caller cancels.
    func waitForUpload(
        cid: String,
        progressToken: JSONValue?,
        sessionID: UUID
    ) async throws -> URL {
        // Check if the upload already arrived before the expectation was registered
        if let earlyArrival = earlyArrivals.removeValue(forKey: cid) {
            return earlyArrival.fileURL
        }
        if let earlyFailure = earlyFailures.removeValue(forKey: cid) {
            throw earlyFailure.error
        }

        return try await withCheckedThrowingContinuation { continuation in
            expectations[cid] = Expectation(
                continuation: continuation,
                progressToken: progressToken,
                sessionID: sessionID
            )
        }
    }

    /// Result of a fulfill attempt.
    enum FulfillResult {
        /// Expectation was waiting — upload delivered, tool call resumed.
        case fulfilled(progressToken: JSONValue?)
        /// No expectation yet — stored as early arrival for later pickup.
        case earlyArrival
        /// No expectation and not stored — CID was unknown.
        case missed
    }

    /// Fulfill a pending upload with a temp file URL. Called by the upload endpoint.
    /// If no expectation exists yet, stores the upload as an early arrival.
    @discardableResult
    func fulfill(cid: String, fileURL: URL) -> FulfillResult {
        guard let expectation = expectations.removeValue(forKey: cid) else {
            // No expectation yet — store as early arrival
            if let replaced = earlyArrivals[cid], replaced.fileURL != fileURL {
                try? FileManager.default.removeItem(at: replaced.fileURL)
            }
            earlyFailures.removeValue(forKey: cid)
            earlyArrivals[cid] = EarlyArrival(fileURL: fileURL, arrivedAt: Date())
            return .earlyArrival
        }
        expectation.continuation.resume(returning: fileURL)
        return .fulfilled(progressToken: expectation.progressToken)
    }

    /// Fail a pending upload (e.g. on cancellation or timeout).
    /// A failure with no expectation yet waits for the tool call, within the cap.
    func fail(cid: String, error: Error) {
        guard let expectation = expectations.removeValue(forKey: cid) else {
            if let replaced = earlyArrivals.removeValue(forKey: cid) {
                try? FileManager.default.removeItem(at: replaced.fileURL)
            }
            if earlyFailures.count >= Self.maxEarlyFailures,
               let oldest = earlyFailures.min(by: { $0.value.order < $1.value.order }) {
                earlyFailures.removeValue(forKey: oldest.key)
            }
            failureCount += 1
            earlyFailures[cid] = EarlyFailure(error: error, failedAt: Date(), order: failureCount)
            return
        }
        expectation.continuation.resume(throwing: error)
    }

    /// Cancel all pending uploads for a session.
    func cancelAll(sessionID: UUID, error: Error) {
        let matching = expectations.filter { $0.value.sessionID == sessionID }
        for (cid, expectation) in matching {
            expectations.removeValue(forKey: cid)
            expectation.continuation.resume(throwing: error)
        }
    }

    /// Check if a CID is expected or has already arrived early.
    func isExpectedOrArrived(cid: String) -> Bool {
        expectations[cid] != nil || earlyArrivals[cid] != nil
    }

    /// Get the progress token for a CID (for sending progress notifications during upload).
    func progressToken(for cid: String) -> JSONValue? {
        expectations[cid]?.progressToken
    }

    /// Removes early arrivals and failures older than the given interval, deleting the arrivals' files.
    func expireEarlyArrivals(olderThan interval: TimeInterval = 60) {
        let now = Date()
        let expired = earlyArrivals.filter { now.timeIntervalSince($0.value.arrivedAt) > interval }
        for (cid, arrival) in expired {
            earlyArrivals.removeValue(forKey: cid)
            try? FileManager.default.removeItem(at: arrival.fileURL)
        }
        earlyFailures = earlyFailures.filter { now.timeIntervalSince($0.value.failedAt) <= interval }
    }
}
