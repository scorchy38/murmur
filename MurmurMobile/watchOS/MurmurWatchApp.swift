import SwiftUI
import MurmurKit

@main
struct MurmurWatchApp: App {
    @StateObject private var store = MurmurStore()
    @StateObject private var syncService = SyncService(deviceName: "Watch")

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
                .environmentObject(syncService)
        }
    }
}
