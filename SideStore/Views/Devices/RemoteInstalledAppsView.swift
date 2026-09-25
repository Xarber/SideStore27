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
    @Published private(set) var refreshingAppIDs = Set<String>()
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
            let installed = try await DeviceOperationSession.run(target: target) {
                try await RemoteDeviceOperations.listApps()
            }
            let managedIDs = Set(InstalledApp.all(in: DatabaseManager.shared.viewContext)
                .map(\.resignedBundleIdentifier))
            apps = installed.filter { managedIDs.contains($0.bundleId) }
        } catch {
            apps = []
            errorMessage = error.localizedDescription
        }
    }

    func refresh(_ bundleID: String, using action: (String, @escaping () -> Void) -> Void) {
        guard refreshingAppIDs.insert(bundleID).inserted else { return }
        action(bundleID) { [weak self] in
            Task { @MainActor in
                self?.refreshingAppIDs.remove(bundleID)
                await self?.load()
            }
        }
    }
}

struct RemoteInstalledAppsView: View {
    @StateObject private var model: RemoteInstalledAppsViewModel
    let refreshApp: (String, @escaping () -> Void) -> Void

    init(target: CommandTarget, refreshApp: @escaping (String, @escaping () -> Void) -> Void) {
        _model = StateObject(wrappedValue: RemoteInstalledAppsViewModel(target: target))
        self.refreshApp = refreshApp
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.target.name)'s Apps").font(.headline)
                    Text("Apps managed by this SideStore")
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
                        Text("No Managed Apps").font(.headline)
                        Text("No apps managed by this SideStore were found on \(model.target.name).")
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
                            Spacer()
                            SwiftUI.Button {
                                model.refresh(app.bundleId, using: refreshApp)
                            } label: {
                                if model.refreshingAppIDs.contains(app.bundleId) {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(model.refreshingAppIDs.contains(app.bundleId))
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Refresh \(app.name)")
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
