import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the pending upload store deletes its temp files.
@Suite("Pending upload store")
struct PendingUploadStoreTests {
    /// Returns the URL of a new temp file holding one byte.
    private func makeTempFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-upload-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        return url
    }

    /// Checks that a second early arrival for the same CID deletes the first one's file.
    @Test func replacedEarlyArrivalIsDeleted() async {
        let store = PendingUploadStore()
        let first = makeTempFile()
        let second = makeTempFile()
        defer { try? FileManager.default.removeItem(at: second) }

        await store.fulfill(cid: "file", fileURL: first)
        await store.fulfill(cid: "file", fileURL: second)

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    /// Checks that expiring early arrivals deletes the files of the expired ones.
    @Test func expiredEarlyArrivalIsDeleted() async {
        let store = PendingUploadStore()
        let file = makeTempFile()

        await store.fulfill(cid: "file", fileURL: file)
        await store.expireEarlyArrivals(olderThan: -1)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await !store.isExpectedOrArrived(cid: "file"))
    }

    /// Checks that an early failure fails the wait that follows.
    @Test func earlyFailureFailsTheLaterWait() async {
        let store = PendingUploadStore()
        await store.fail(cid: "file", error: UploadTooLargeError(limit: 1))
        await #expect(throws: UploadTooLargeError.self) {
            _ = try await store.waitForUpload(cid: "file", progressToken: nil, sessionID: UUID())
        }
        #expect(await store.earlyFailures.isEmpty)
    }

    /// Checks that an upload arriving after an early failure replaces it.
    @Test func arrivalReplacesEarlyFailure() async {
        let store = PendingUploadStore()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        await store.fail(cid: "file", error: UploadTooLargeError(limit: 1))
        await store.fulfill(cid: "file", fileURL: file)
        #expect(await store.earlyFailures.isEmpty)
        #expect(await store.isExpectedOrArrived(cid: "file"))
    }

    /// Checks that expiring drops old early failures.
    @Test func expiredEarlyFailureIsDropped() async {
        let store = PendingUploadStore()
        await store.fail(cid: "file", error: UploadTooLargeError(limit: 1))
        await store.expireEarlyArrivals(olderThan: -1)
        #expect(await store.earlyFailures.isEmpty)
    }

    /// Checks that the store keeps only the newest early failures up to its cap.
    @Test func earlyFailuresAreCapped() async {
        let store = PendingUploadStore()
        for index in 0...PendingUploadStore.maxEarlyFailures {
            await store.fail(cid: "file-\(index)", error: UploadTooLargeError(limit: 1))
        }
        #expect(await store.earlyFailures.count == PendingUploadStore.maxEarlyFailures)
        #expect(await store.earlyFailures["file-0"] == nil)
        #expect(await store.earlyFailures["file-\(PendingUploadStore.maxEarlyFailures)"] != nil)
    }
}
