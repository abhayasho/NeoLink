import SwiftUI

struct RecentProjectsView: View {
    @ObservedObject var access: WorkspaceAccess
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent Projects")
                .font(.system(size: 18, weight: .semibold))
            Text("Remove shortcuts without deleting folders or closing your current project.")
                .font(.system(size: 12))
                .foregroundStyle(NeoLinkTheme.textSecondary)
            if access.recentFolders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 24))
                    Text("No recent projects")
                    if access.hasSavedFolders {
                        Text("Some saved folders are unavailable. Clear the list to forget them too.")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(NeoLinkTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(access.recentFolders, id: \.self) { url in
                            VStack(spacing: 0) {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(NeoLinkTheme.textSecondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                        Text(url.path)
                                            .font(.system(size: 11))
                                            .foregroundStyle(NeoLinkTheme.textSecondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Button { access.forget(url) } label: {
                                        Image(systemName: "xmark")
                                            .frame(width: 22, height: 22)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove from recent projects")
                                    .accessibilityLabel("Remove \(url.path) from recent projects")
                                }
                                .padding(10)
                                .help(url.path)
                                .accessibilityElement(children: .contain)
                                Divider()
                            }
                        }
                    }
                }
                .background(NeoLinkTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Clear Recent Projects") { access.clearRecentFolders() }
                    .disabled(!access.hasSavedFolders)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 510, height: 360)
        .foregroundStyle(NeoLinkTheme.textPrimary)
        .background(NeoLinkTheme.sidebarBackground)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
    }
}
