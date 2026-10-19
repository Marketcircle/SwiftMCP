import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A session delegate that follows a redirect only when it stays on the original request's origin.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// The delegate every client session shares.
    static let shared = SameOriginRedirectDelegate()

    /// Returns whether a redirect from the first URL to the second stays on one origin.
    static func allowsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return target.hasSameOrigin(as: original)
    }

    /// Follows the redirect on the original request's origin, and delivers the redirect response otherwise.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}

extension URLSession {
    /// Returns a session with the given configuration that refuses redirects to another origin.
    static func sameOrigin(configuration: URLSessionConfiguration = .default) -> URLSession {
        URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate.shared, delegateQueue: nil)
    }
}
