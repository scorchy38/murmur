import SwiftUI
import MurmurKit

@main
struct MurmurApp: App {
    @StateObject private var store = MurmurStore()
    @StateObject private var syncService = SyncService(deviceName: "iPhone")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(syncService)
        }
    }
}
