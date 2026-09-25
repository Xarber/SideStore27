//
//  RemoteInstalledAppsView.swift
//  SideStore
//

import SwiftUI

#if !os(tvOS)
@MainActor
final class RemoteInstalledAppsViewModel: ObservableObject {
    @Published private(set) var apps: [RemoteDeviceOperations.InstalledApplication] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let target: CommandTarget

    init(target: CommandTarget) {
        self.target = target
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apps = try await DeviceOperationSession.run(target: target) {
                try await RemoteDeviceOperations.listApps()
            }
        } catch {
            apps = []
            errorMessage = error.localizedDescription
        }
    }
}

struct RemoteInstalledAppsView: View {
    @StateObject private var model: RemoteInstalledAppsViewModel

    init(target: CommandTarget) {
        _model = StateObject(wrappedValue: RemoteInstalledAppsViewModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.target.name).font(.headline)
                    Text("Installed apps on the selected device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SwiftUI.Button { Task { await model.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityLabel("Refresh Remote Apps")
            }
            .padding()

            Group {
                if model.isLoading && model.apps.isEmpty {
                    ProgressView("Loading apps from \(model.target.name)…")
                } else if let error = model.errorMessage, model.apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("Unable to Load Apps").font(.headline)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        SwiftUI.Button("Try Again") { Task { await model.load() } }
                    }.padding()
                } else if model.apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.slash").font(.largeTitle)
                        Text("No User Apps").font(.headline)
                        Text("No user-installed apps were reported by \(model.target.name).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.padding()
                } else {
                    List(model.apps) { app in
                        HStack(spacing: 12) {
                            Image(systemName: "app.dashed")
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name.isEmpty ? app.bundleId : app.name)
                                    .font(.body.weight(.semibold))
                                Text(app.bundleId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !app.version.isEmpty || !app.buildVersion.isEmpty {
                                    Text([app.version, app.buildVersion.isEmpty ? nil : "(\(app.buildVersion))"]
                                        .compactMap { $0 }.joined(separator: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .refreshable { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.load() }
    }
}
#endif
