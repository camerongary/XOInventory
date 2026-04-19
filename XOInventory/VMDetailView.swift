//
//  VMDetailView.swift
//  XOInventory
//

import SwiftUI

struct VMDetailView: View {
    let vm: VM
    let diskBytes: Int64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(vm.nameLabel)
                            .font(.title3).bold()
                            .lineLimit(2)
                        Spacer()
                        PowerStatePill(state: vm.powerState)
                    }
                    if let desc = vm.nameDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                section("Resources") {
                    row("vCPUs", vm.cpuDisplay)
                    row("Memory", vm.memoryDisplay)
                    row("Total Disk",
                        diskBytes > 0 ? VM.byteFormatter.string(fromByteCount: diskBytes) : "—")
                    row("Attached VDIs", "\(vm.vdiRefs.count)")
                }

                section("Network") {
                    row("Primary IP", vm.ipDisplay, mono: true)
                    if !vm.otherIpAddresses.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All Addresses")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(vm.otherIpAddresses, id: \.self) { ip in
                                Text(ip).monospaced().font(.callout)
                            }
                        }
                    }
                }

                section("System") {
                    row("OS", vm.os ?? "—")
                    row("UUID", vm.uuid, mono: true, selectable: true)
                    if let host = vm.host {
                        row("Host", host, mono: true, selectable: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, mono: Bool = false, selectable: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.callout)
            .if(mono) { $0.monospaced() }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Small conditional-modifier helper used above.
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

#Preview {
    VMDetailView(
        vm: VM(
            uuid: "770aa52a-fd42-8faf-f167-8c5c4a237cac",
            nameLabel: "debian-build-01",
            powerState: "Running",
            cpus: 4,
            memoryBytes: 4 * 1024 * 1024 * 1024,
            mainIpAddress: "10.0.0.42",
            otherIpAddresses: ["10.0.0.42", "192.168.100.5"],
            os: "Debian GNU/Linux 12",
            host: "abc-123",
            nameDescription: "Jenkins build agent"
        ),
        diskBytes: 40 * 1024 * 1024 * 1024
    )
    .frame(width: 320, height: 500)
}
