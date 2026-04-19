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
        if let ip = mainIpAddress, !ip.isEmpty { return ip }
        if let first = otherIpAddresses.first { return first }
        return "—"
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
        cpus = try? c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try? c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        mainIpAddress = try? c.decodeIfPresent(String.self, forKey: .mainIpAddress)

        // `addresses` is a dictionary like {"0/ip": "10.0.0.4", "0/ipv6/0": "..."}.
        if let addrDict = try? c.decodeIfPresent([String: String].self, forKey: .addresses) {
            otherIpAddresses = addrDict
                .filter { !$0.key.contains("ipv6") }
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
    let residentVMCount: Int?         // VMs currently running on this host

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
        case residentVmCount = "residentVmCount"
        case resident_VMs
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

        // Number of VMs running on this host. XO returns residentVmCount directly in newer
        // versions; on older builds, fall back to counting the resident_VMs array.
        if let n = try? c.decodeIfPresent(Int.self, forKey: .residentVmCount) {
            residentVMCount = n
        } else if let arr = try? c.decodeIfPresent([String].self, forKey: .resident_VMs) {
            residentVMCount = arr.count
        } else {
            residentVMCount = nil
        }
    }

    // Preview / manual init
    init(uuid: String, nameLabel: String, address: String?,
         cpuCount: Int?, memoryTotalBytes: Int64?, memoryUsageBytes: Int64?,
         version: String? = nil, cpuModel: String? = nil,
         cpuSpeedMHz: Double? = nil, residentVMCount: Int? = nil,
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
        self.residentVMCount = residentVMCount
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

// MARK: - Connection

/// User-entered connection details. The app never writes the token to disk —
/// it is held in memory for the session only.
struct XOConnection: Equatable {
    var host: String = ""          // e.g. "xo.lan" or "10.0.0.5"
    var token: String = ""
    var allowSelfSignedCert: Bool = true  // homelab default

    init(host: String = "", token: String = "", allowSelfSignedCert: Bool = true) {
        self.host = host
        self.token = token
        self.allowSelfSignedCert = allowSelfSignedCert
    }

    var baseURL: URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        // Strip trailing slash if present so we can append cleanly.
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    var isValid: Bool {
        baseURL != nil && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
