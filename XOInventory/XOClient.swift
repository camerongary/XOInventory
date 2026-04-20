//
//  XOClient.swift
//  XOInventory
//
//  Thin async client for the Xen Orchestra REST API (v0).
//  Reference: https://docs.xen-orchestra.com/restapi
//

import Foundation

enum XOClientError: LocalizedError {
    case invalidURL
    case httpStatus(Int, String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The host URL is not valid."
        case .httpStatus(let code, let body):
            if code == 401 {
                return "Authentication failed (401). Check the token and that the user has admin rights."
            }
            if let body, !body.isEmpty {
                return "Server returned HTTP \(code): \(body.prefix(200))"
            }
            return "Server returned HTTP \(code)."
        case .decoding(let err):
            return "Could not decode the response: \(err.localizedDescription)"
        case .transport(let err):
            let nserr = err as NSError
            if nserr.domain == NSURLErrorDomain {
                switch nserr.code {
                case NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateNotYetValid:
                    return "The server's TLS certificate is not trusted. Enable 'Allow self-signed certificate' for homelab hosts."
                case NSURLErrorCannotConnectToHost:
                    return "Cannot connect to host. Check the IP/hostname and that XO is reachable."
                case NSURLErrorTimedOut:
                    return "Connection timed out."
                default:
                    break
                }
            }
            return "Network error: \(err.localizedDescription)"
        }
    }
}

/// Actor-based client so concurrent refreshes don't race on the URLSession config.
actor XOClient {
    private let connection: XOConnection
    private let session: URLSession

    /// Cached base URL once we've figured out whether this host speaks HTTPS or HTTP.
    /// Nil until the first successful probe. Subsequent requests reuse this.
    private var resolvedBaseURL: URL?

    init(connection: XOConnection) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        if connection.allowSelfSignedCert {
            self.session = URLSession(
                configuration: config,
                delegate: InsecureTLSDelegate(),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Fetch all VMs with the fields we need for the inventory.
    /// Uses the `fields=` query param so XO returns full objects instead of href stubs.
    func fetchVMs() async throws -> [VM] {
        let fields = "uuid,name_label,name_description,power_state,CPUs,memory,mainIpAddress,addresses,os_version,$container,$VBDs"
        var comps = try await baseComponents(path: "/rest/v0/vms")
        comps.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let url = try resolve(comps)

        let data = try await get(url)
        do {
            return try JSONDecoder().decode([VM].self, from: data)
        } catch {
            throw XOClientError.decoding(error)
        }
    }

    /// Fetch all hosts (hypervisors) in the pool.
    func fetchHosts() async throws -> [Host] {
        let fields = "uuid,name_label,name_description,address,power_state,enabled,version,CPUs,memory"
        var comps = try await baseComponents(path: "/rest/v0/hosts")
        comps.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let url = try resolve(comps)

        let data = try await get(url)
        do {
            return try JSONDecoder().decode([Host].self, from: data)
        } catch {
            throw XOClientError.decoding(error)
        }
    }

    /// Fetch all storage repositories. Used to compute per-host disk totals.
    func fetchSRs() async throws -> [SR] {
        let fields = "uuid,name_label,SR_type,shared,size,physical_usage,$container"
        var comps = try await baseComponents(path: "/rest/v0/srs")
        comps.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let url = try resolve(comps)

        let data = try await get(url)
        do {
            return try JSONDecoder().decode([SR].self, from: data)
        } catch {
            throw XOClientError.decoding(error)
        }
    }

    /// Verify the host is reachable and the token is valid. Returns (hostCount, vmCount).
    /// Used by the "Test Connection" button in the profile editor.
    func testConnection() async throws -> (hosts: Int, vms: Int) {
        try await probe()
        async let hostsTask = fetchHosts()
        async let vmsTask = fetchVMs()
        let (hosts, vms) = try await (hostsTask, vmsTask)
        return (hosts.count, vms.count)
    }

    /// Fetch VDIs (disks) for a single VM and return the summed size.
    /// XO exposes VDIs under /rest/v0/vms/{uuid}/vdis. If that endpoint isn't
    /// present on the running XO version, return 0 rather than failing the whole refresh.
    func fetchTotalDiskBytes(vmUUID: String) async -> Int64 {
        var comps = (try? await baseComponents(path: "/rest/v0/vms/\(vmUUID)/vdis")) ?? URLComponents()
        comps.queryItems = [URLQueryItem(name: "fields", value: "uuid,name_label,size")]
        guard let url = try? resolve(comps) else { return 0 }

        do {
            let data = try await get(url)
            let vdis = try JSONDecoder().decode([VDI].self, from: data)
            return vdis.compactMap { $0.size }.reduce(0, +)
        } catch {
            return 0
        }
    }

    /// Cheap connectivity/auth check against the API root.
    /// Tries HTTPS first; if HTTPS fails with a hard connection error (not auth,
    /// not cert trust), silently falls back to HTTP. Caches the working scheme.
    /// If the user explicitly typed a scheme, we use only that.
    func probe() async throws {
        if resolvedBaseURL != nil {
            // Already resolved earlier in this client's lifetime. Just verify it still works.
            let url = try apiRootURL()
            _ = try await get(url)
            return
        }

        if connection.hasExplicitScheme {
            // User was explicit. Don't probe the other scheme.
            guard let url = connection.url(scheme: "https") else {
                throw XOClientError.invalidURL
            }
            let root = url.appendingPathComponent("rest/v0/")
            _ = try await get(root)
            resolvedBaseURL = url
            return
        }

        // Try HTTPS first.
        if let httpsBase = connection.url(scheme: "https") {
            let httpsRoot = httpsBase.appendingPathComponent("rest/v0/")
            do {
                _ = try await get(httpsRoot)
                resolvedBaseURL = httpsBase
                return
            } catch let XOClientError.transport(err) where Self.isConnectionRefusal(err) {
                // HTTPS isn't listening. Try HTTP.
            } catch {
                // Any other error (401, cert trust, 404, etc.) is meaningful — surface it.
                throw error
            }
        }

        // Fall back to HTTP.
        guard let httpBase = connection.url(scheme: "http") else {
            throw XOClientError.invalidURL
        }
        let httpRoot = httpBase.appendingPathComponent("rest/v0/")
        _ = try await get(httpRoot)
        resolvedBaseURL = httpBase
    }

    /// True when the error is "TCP connection was refused" — the signal we use
    /// to decide HTTPS is not listening on this host and we should try HTTP.
    private static func isConnectionRefusal(_ error: Error) -> Bool {
        let nserr = error as NSError
        guard nserr.domain == NSURLErrorDomain else { return false }
        switch nserr.code {
        case NSURLErrorCannotConnectToHost,     // ECONNREFUSED
             NSURLErrorCannotFindHost,          // defensive; shouldn't happen once ping works
             NSURLErrorSecureConnectionFailed:  // no TLS stack at all on the other end
            return true
        default:
            return false
        }
    }

    // MARK: - Internals

    /// The resolved API base URL (scheme + host). Valid only after probe().
    private func apiRootURL() throws -> URL {
        guard let base = resolvedBaseURL else {
            throw XOClientError.invalidURL
        }
        return base.appendingPathComponent("rest/v0/")
    }

    private func baseComponents(path: String) async throws -> URLComponents {
        // Lazily resolve the scheme if a fetch method was called before probe().
        if resolvedBaseURL == nil {
            try await probe()
        }
        guard let base = resolvedBaseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw XOClientError.invalidURL
        }
        comps.path = path
        return comps
    }

    private func resolve(_ comps: URLComponents) throws -> URL {
        guard let url = comps.url else { throw XOClientError.invalidURL }
        return url
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Cookie-style auth as documented: Cookie: authenticationToken=<token>
        let cookie = "authenticationToken=\(connection.token.trimmingCharacters(in: .whitespacesAndNewlines))"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw XOClientError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw XOClientError.httpStatus(-1, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw XOClientError.httpStatus(http.statusCode, body)
        }
        return data
    }
}

// MARK: - TLS delegate for self-signed homelab certs

/// Trusts any server cert. ONLY used when the user opts in.
/// Do not ship a variant of this app that trusts all certs unconditionally.
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
