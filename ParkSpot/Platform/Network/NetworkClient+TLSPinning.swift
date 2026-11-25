import Foundation
import CryptoKit
import OSLog
import Security

extension NetworkClient: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        let pinnedHosts = Set(AppConfig.tlsPinnedHosts)

        // Pinning s'applique seulement aux hosts explicitement ciblés.
        guard pinnedHosts.contains(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let pinHashes = Set(AppConfig.tlsPinnedCertificateSHA256.map(Self.normalizeHash))

        if pinHashes.isEmpty {
            if AppConfig.enforceTLSPinning {
                logger.fault("TLS pinning activé mais aucune empreinte configurée pour l'hôte \(host, privacy: .public)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                logger.error("TLS pinning non configuré pour \(host, privacy: .public), fallback validation système")
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        guard let trust = challenge.protectionSpace.serverTrust else {
            logger.error("Challenge TLS sans trust pour \(host, privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            logger.error("Échec évaluation trust pour \(host, privacy: .public): \(String(describing: trustError), privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chainHashes = Self.certificateChainSHA256Hex(trust: trust)
        let hasPinnedMatch = chainHashes.contains { pinHashes.contains($0) }

        guard hasPinnedMatch else {
            logger.fault("Aucune empreinte TLS correspondante pour \(host, privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    nonisolated static func certificateChainSHA256Hex(trust: SecTrust) -> [String] {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return []
        }

        return chain.map { cert in
            let derData = SecCertificateCopyData(cert) as Data
            let hash = SHA256.hash(data: derData)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated static func normalizeHash(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }
}
