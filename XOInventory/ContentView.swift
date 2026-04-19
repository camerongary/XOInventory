//
//  ContentView.swift
//  XOInventory
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = InventoryViewModel()
    @StateObject private var store = ProfileStore()
    @State private var activeProfile: HostProfile?

    var body: some View {
        Group {
            if let profile = activeProfile {
                InventoryView(
                    viewModel: viewModel,
                    hostDisplay: "\(profile.name) — \(profile.host)",
                    onDisconnect: {
                        viewModel.disconnect()
                        activeProfile = nil
                    }
                )
            } else {
                ConnectionView(
                    store: store,
                    viewModel: viewModel,
                    onConnected: { profile in
                        activeProfile = profile
                    }
                )
            }
        }
    }
}

#Preview {
    ContentView()
}
