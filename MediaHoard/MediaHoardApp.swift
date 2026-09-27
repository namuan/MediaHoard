import SwiftUI

@main
struct MediaHoardApp: App {
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
        }
    }
}
