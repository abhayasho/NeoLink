import SwiftUI

struct RemoteDesktopPlaceholderView: View {
    var body: some View {
        VStack {
            Text("Remote desktop sessions (RDP/VNC) will appear here.")
                .font(.headline)
            Text("Implementation will embed platform-specific RDP/VNC views.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

