//
//  Models.swift
//  XOInventory
//
//  Decodable models that match the shape returned by the XO REST API
//  when querying /rest/v0/vms with a `fields=` projection.
//

import Foundation

// MARK: - VM

/// A single VM as returned by the XO REST API.
///
/// We only decode the fields we project with `fields=`, which keeps payloads small
/// and makes the decoder tolerant of schema drift between XO versions.
struct VM: Identifiable, Hashable, Decodable {
    let uuid: String
    let nameLabel: String
    let nameDescription: String?
    let powerState: String          // "Running", "Halted", "Paused", "Suspended"
    let cpus: Int?                  // vCPUs
    let memoryBytes: Int64?         // RAM in bytes
    let mainIpAddress: String?      // primary IP, best-effort
    let otherIpAddresses: [String]  // additional IPs from guest tools
    let os: String?                 // reported OS
    let host: String?               // host UUID the VM runs on
    let vdiRefs: [String]           // disks attached to the VM

    // Convenience
    var id: String { uuid }

    var memoryDisplay: String {
        guard let bytes = memoryBytes else { return "—" }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    var cpuDisplay: String {
        cpus.map(String.init) ?? "—"
    }

    var ipDisplay: String {
        // Prefer a v4 address if we have one. Some guests (Windows especially)
        // report an IPv6 as the primary address, which is technically correct
        // but unhelpful for admins looking at the table.
        if let ip = mainIpAddress, !ip.isEmpty, Self.isIPv4(ip) { return ip }
        if let v4 = otherIpAddresses.first(where: Self.isIPv4) { return v4 }
        if let ip = mainIpAddress, !ip.isEmpty { return ip }
        if let first = otherIpAddresses.first { return first }
        return "—"
    }

    /// Quick IPv4 heuristic — three dots, no colons. Good enough here; we
    /// don't need full address parsing for display purposes.
    private static func isIPv4(_ s: String) -> Bool {
        !s.contains(":") && s.split(separator: ".").count == 4
    }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .binary
        f.includesUnit = true
        return f
    }()

    // The XO API uses snake_case; map explicitly.
    enum CodingKeys: String, CodingKey {
        case uuid
        case nameLabel = "name_label"
        case nameDescription = "name_description"
        case powerState = "power_state"
        case cpus = "CPUs"
        case memoryBytes = "memory"
        case mainIpAddress = "mainIpAddress"
        case addresses
        case os = "os_version"
        case host = "$container"
        case vdiRefs = "$VBDs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        nameLabel = try c.decodeIfPresent(String.self, forKey: .nameLabel) ?? "(unnamed)"
        nameDescription = try c.decodeIfPresent(String.self, forKey: .nameDescription)
        powerState = try c.decodeIfPresent(String.self, forKey: .powerState) ?? "Unknown"

        // XO returns CPUs as either:
        //   - a plain integer:       4
        //   - a nested object:       { "number": 4, "max": 8 }
        // Memory is either:
        //   - a plain integer:       4294967296
        //   - a nested object:       { "size": 4297039872, "dynamic": [...], "static": [...] }
        // Handle both so we stay robust across XO versions.
        cpus = Self.decodeIntOrObjectInt(c, key: .cpus, preferredObjectKeys: ["number", "max"])
        memoryBytes = Self.decodeInt64OrObjectInt64(c, key: .memoryBytes, preferredObjectKeys: ["size"])

        mainIpAddress = try? c.decodeIfPresent(String.self, forKey: .mainIpAddress)

        // `addresses` is a dictionary like {"0/ip": "10.0.0.4", "0/ipv6/0": "..."}.
        // Keep both v4 and v6 here — ipDisplay prefers v4 when picking one.
        if let addrDict = try? c.decodeIfPresent([String: String].self, forKey: .addresses) {
            otherIpAddresses = addrDict
                .map { $0.value }
                .filter { !$0.isEmpty }
                .sorted()
        } else {
            otherIpAddresses = []
        }

        // os_version is sometimes a dict with a "name" key, sometimes absent.
        if let osDict = try? c.decodeIfPresent([String: String].self, forKey: .os) {
            os = osDict["name"] ?? osDict["distro"]
        } else {
            os = try? c.decodeIfPresent(String.self, forKey: .os)
        }

        host = try? c.decodeIfPresent(String.self, forKey: .host)
        vdiRefs = (try? c.decodeIfPresent([String].self, forKey: .vdiRefs)) ?? []
    }

    // MARK: - Tolerant decoding helpers

    /// Decodes a field that may be a plain Int or a nested object containing
    /// one of the given keys. Works even when the object has mixed-type values
    /// (like XO's `memory` which mixes ints and arrays).
    private static func decodeIntOrObjectInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        preferredObjectKeys: [String]
    ) -> Int? {
        if let n = try? container.decodeIfPresent(Int.self, forKey: key) {
            return n
        }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(d)
        }
        // Object case: open a nested container and try each preferred key.
        guard let nested = try? container.nestedContainer(
            keyedBy: DynamicKey.self, forKey: key) else { return nil }
        for name in preferredObjectKeys {
            guard let k = DynamicKey(stringValue: name) else { continue }
            if let v = try? nested.decodeIfPresent(Int.self, forKey: k) { return v }
            if let v = try? nested.decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        }
        return nil
    }

    /// Same idea for Int64 (memory in bytes).
    private static func decodeInt64OrObjectInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        preferredObjectKeys: [String]
    ) -> Int64? {
        if let n = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return n
        }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int64(d)
        }
        guard let nested = try? container.nestedContainer(
            keyedBy: DynamicKey.self, forKey: key) else { return nil }
        for name in preferredObjectKeys {
            guard let k = DynamicKey(stringValue: name) else { continue }
            if let v = try? nested.decodeIfPresent(Int64.self, forKey: k) { return v }
            if let v = try? nested.decodeIfPresent(Double.self, forKey: k) { return Int64(v) }
        }
        return nil
    }

    /// Arbitrary-string CodingKey so we can peek at nested JSON object keys.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.stringValue = String(intValue)
        }
    }

    // For previews / manual init
    init(uuid: String, nameLabel: String, powerState: String,
         cpus: Int?, memoryBytes: Int64?, mainIpAddress: String?,
         otherIpAddresses: [String] = [], os: String? = nil,
         host: String? = nil, vdiRefs: [String] = [],
         nameDescription: String? = nil) {
        self.uuid = uuid
        self.nameLabel = nameLabel
        self.nameDescription = nameDescription
        self.powerState = powerState
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.mainIpAddress = mainIpAddress
        self.otherIpAddresses = otherIpAddresses
        self.os = os
        self.host = host
        self.vdiRefs = vdiRefs
    }
}

// MARK: - Disk

/// A virtual disk (VDI). We roll these up per VM to show total disk space.
struct VDI: Decodable {
    let uuid: String
    let nameLabel: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case uuid
        case nameLabel = "name_label"
        case size
    }
}

// MARK: - Host

/// An XCP-NG host (hypervisor) in a pool. Returned from /rest/v0/hosts.
struct Host: Identifiable, Hashable, Decodable {
    let uuid: String
    let nameLabel: String
    let nameDescription: String?
    let address: String?              // management IP
    let powerState: String?           // "Running", "Halted"
    let enabled: Bool?                // scheduling enabled
    let version: String?              // xcp-ng version
    let cpuCount: Int?                // logical CPUs
    let cpuModel: String?
    let cpuSpeedMHz: Double?
    let memoryTotalBytes: Int64?
    let memoryUsageBytes: Int64?
    // Note: VMs-per-host is computed by the view model from the VM list,
    // because some XO versions don't include it on the host record.

    var id: String { uuid }

    var memoryTotalDisplay: String {
        memoryTotalBytes.map { VM.byteFormatter.string(fromByteCount: $0) } ?? "—"
    }

    var memoryUsageDisplay: String {
        memoryUsageBytes.map { VM.byteFormatter.string(fromByteCount: $0) } ?? "—"
    }

    /// Percentage of RAM in use, 0…1. Nil if we don't have both values.
    var memoryUsageFraction: Double? {
        guard let total = memoryTotalBytes, total > 0,
              let used = memoryUsageBytes else { return nil }
        return Double(used) / Double(total)
    }

    var cpuDisplay: String {
        guard let count = cpuCount else { return "—" }
        if let mhz = cpuSpeedMHz, mhz > 0 {
            let ghz = mhz / 1000
            return String(format: "%d × %.2f GHz", count, ghz)
        }
        return "\(count)"
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case nameLabel = "name_label"
        case nameDescription = "name_description"
        case address
        case powerState = "power_state"
        case enabled
        case version
        case cpus = "CPUs"
        case memory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        nameLabel = try c.decodeIfPresent(String.self, forKey: .nameLabel) ?? "(unnamed)"
        nameDescription = try c.decodeIfPresent(String.self, forKey: .nameDescription)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        powerState = try? c.decodeIfPresent(String.self, forKey: .powerState)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        version = try? c.decodeIfPresent(String.self, forKey: .version)

        // CPUs is an object on hosts: { cpu_count: "32", speed: "2400", modelname: "..." }
        // Values are sometimes strings, sometimes numbers — be tolerant.
        if let cpuBlob = try? c.decodeIfPresent(AnyJSON.self, forKey: .cpus)?.value as? [String: Any] {
            cpuCount = (cpuBlob["cpu_count"] as? Int) ?? Int("\(cpuBlob["cpu_count"] ?? "")")
            cpuSpeedMHz = (cpuBlob["speed"] as? Double) ?? Double("\(cpuBlob["speed"] ?? "")")
            cpuModel = cpuBlob["modelname"] as? String
        } else {
            cpuCount = nil
            cpuSpeedMHz = nil
            cpuModel = nil
        }

        // memory is an object: { size: <bytes>, usage: <bytes> }
        if let memBlob = try? c.decodeIfPresent(AnyJSON.self, forKey: .memory)?.value as? [String: Any] {
            memoryTotalBytes = (memBlob["size"] as? Int64) ?? Int64("\(memBlob["size"] ?? "")")
            memoryUsageBytes = (memBlob["usage"] as? Int64) ?? Int64("\(memBlob["usage"] ?? "")")
        } else {
            memoryTotalBytes = nil
            memoryUsageBytes = nil
        }
    }

    // Preview / manual init
    init(uuid: String, nameLabel: String, address: String?,
         cpuCount: Int?, memoryTotalBytes: Int64?, memoryUsageBytes: Int64?,
         version: String? = nil, cpuModel: String? = nil,
         cpuSpeedMHz: Double? = nil,
         powerState: String? = "Running", enabled: Bool? = true,
         nameDescription: String? = nil) {
        self.uuid = uuid
        self.nameLabel = nameLabel
        self.nameDescription = nameDescription
        self.address = address
        self.powerState = powerState
        self.enabled = enabled
        self.version = version
        self.cpuCount = cpuCount
        self.cpuModel = cpuModel
        self.cpuSpeedMHz = cpuSpeedMHz
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsageBytes = memoryUsageBytes
    }
}

/// Helper: decodes arbitrary JSON so we can poke at nested XO objects that
/// change shape across versions (CPUs, memory, etc.).
private struct AnyJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([String: AnyJSON].self) {
            value = v.mapValues { $0.value }
        }
        else if let v = try? c.decode([AnyJSON].self) {
            value = v.map { $0.value }
        }
        else { value = NSNull() }
    }
}

// MARK: - SR (Storage Repository)

/// An XCP-NG storage repository. Returned from /rest/v0/srs.
/// Local SRs have $container set to a host UUID; shared SRs have $container
/// set to the pool UUID.
struct SR: Identifiable, Hashable, Decodable {
    let uuid: String
    let nameLabel: String
    let srType: String?          // "udev", "ext", "nfs", "iso", "lvm", etc.
    let shared: Bool
    let size: Int64              // total capacity in bytes. -1 means "unknown"
    let physicalUsage: Int64     // used bytes
    let container: String        // host UUID (local) or pool UUID (shared)

    var id: String { uuid }

    /// SRs we want to exclude from disk totals: removable drives, ISO stores.
    /// They're real SRs but don't represent usable VM storage.
    var isUsableStorage: Bool {
        switch srType?.lowercased() {
        case "udev", "iso": return false     // removable devices, ISO stores
        default: return size > 0             // size == -1 means XO doesn't know
        }
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case nameLabel = "name_label"
        case srType = "SR_type"
        case shared
        case size
        case physicalUsage = "physical_usage"
        case container = "$container"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        nameLabel = try c.decodeIfPresent(String.self, forKey: .nameLabel) ?? "(unnamed)"
        srType = try? c.decodeIfPresent(String.self, forKey: .srType)
        shared = (try? c.decodeIfPresent(Bool.self, forKey: .shared)) ?? false
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        physicalUsage = (try? c.decodeIfPresent(Int64.self, forKey: .physicalUsage)) ?? 0
        container = try c.decode(String.self, forKey: .container)
    }
}

// MARK: - Connection

/// User-entered connection details. The app never writes the token to disk —
/// it is held in memory for the session only.
struct XOConnection: Equatable {
    var host: String = ""          // e.g. "xo.lan" or "10.0.0.5" — may include scheme
    var token: String = ""
    var allowSelfSignedCert: Bool = true  // homelab default

    init(host: String = "", token: String = "", allowSelfSignedCert: Bool = true) {
        self.host = host
        self.token = token
        self.allowSelfSignedCert = allowSelfSignedCert
    }

    /// True when the user explicitly typed "http://" or "https://". When false,
    /// the client is free to probe both schemes.
    var hasExplicitScheme: Bool {
        let t = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// Build a URL for this host with the given scheme. Used when probing both
    /// schemes automatically. If the user already included a scheme, that wins.
    func url(scheme: String) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if hasExplicitScheme {
            // Respect what the user typed, ignore the requested scheme.
            if trimmed.hasSuffix("/") { trimmed.removeLast() }
            return URL(string: trimmed)
        }
        // Strip any leading "//" just in case.
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: "\(scheme)://\(trimmed)")
    }

    /// The URL we default to when no probing has happened yet. HTTPS first.
    var baseURL: URL? { url(scheme: "https") }

    var isValid: Bool {
        baseURL != nil && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
