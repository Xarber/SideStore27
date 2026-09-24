import CoreData
import Foundation

private struct StoredAccountCredentials: Codable {
    let appleID: String
    let password: String?
    let adsid: String
    let xcodeToken: String
    let certificate: Data?
    let certificatePassword: String?
}

/// Securely keeps credentials per developer account. Selecting an account does
/// not alter the selected command target, and selecting a device does not alter
/// the account.
final class AccountCredentialStore: @unchecked Sendable {
    static let shared = AccountCredentialStore()
    private let lock = NSLock()

    private init() {}

    func captureCurrentAccount(identifier: String) {
        guard let appleID = Keychain.shared.appleIDEmailAddress,
              let adsid = Keychain.shared.appleIDAdsid,
              let token = Keychain.shared.appleIDXcodeToken else { return }
        lock.withLock {
            var records = load()
            records[identifier] = StoredAccountCredentials(
                appleID: appleID,
                password: Keychain.shared.appleIDPassword,
                adsid: adsid,
                xcodeToken: token,
                certificate: Keychain.shared.signingCertificate,
                certificatePassword: Keychain.shared.signingCertificatePassword
            )
            save(records)
        }
    }

    func captureActiveAccount() async {
        if let identifier = await currentAccountIdentifier() {
            captureCurrentAccount(identifier: identifier)
        }
    }

    func hasCredentials(for identifier: String) -> Bool {
        lock.withLock { load()[identifier] != nil }
    }

    func activate(identifier: String) async throws {
        let record = lock.withLock { load()[identifier] }
        guard let record else { throw OperationError.notAuthenticated }

        if let current = await currentAccountIdentifier(), current != identifier {
            captureCurrentAccount(identifier: current)
        }

        Keychain.shared.appleIDEmailAddress = record.appleID
        Keychain.shared.appleIDPassword = record.password
        Keychain.shared.appleIDAdsid = record.adsid
        Keychain.shared.appleIDXcodeToken = record.xcodeToken
        Keychain.shared.signingCertificate = record.certificate
        Keychain.shared.signingCertificatePassword = record.certificatePassword
        AuthManager.shared.invalidateCachedAuthentication()
        _ = try? CertificateManager.shared.loadActiveCertificate()

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            let accounts = try context.fetch(Account.fetchRequest())
            guard let selected = accounts.first(where: { $0.identifier == identifier }) else {
                throw OperationError.notAuthenticated
            }
            accounts.forEach { $0.isActiveAccount = ($0 == selected) }
            let teams = try context.fetch(Team.fetchRequest())
            let selectedTeams = teams.filter { $0.account == selected }
            guard let selectedTeam = selectedTeams.first else { throw OperationError.notAuthenticated }
            teams.forEach { $0.isActiveTeam = ($0 == selectedTeam) }
            try context.save()
        }
        await DatabaseManager.shared.viewContext.perform {
            DatabaseManager.shared.viewContext.refreshAllObjects()
        }
        NotificationCenter.default.post(name: .signingAccountDidChange, object: identifier)
    }

    func availableAccounts() async -> [(identifier: String, appleID: String, isActive: Bool)] {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            let accounts = (try? context.fetch(Account.fetchRequest())) ?? []
            return accounts.map { ($0.identifier, $0.appleID, $0.isActiveAccount) }
                .filter { self.hasCredentials(for: $0.identifier) }
                .sorted { $0.appleID.localizedCaseInsensitiveCompare($1.appleID) == .orderedAscending }
        }
    }

    private func currentAccountIdentifier() async -> String? {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform { DatabaseManager.shared.activeAccount(in: context)?.identifier }
    }

    private func load() -> [String: StoredAccountCredentials] {
        guard let data = Keychain.shared.accountCredentialRecords,
              let records = try? JSONDecoder().decode([String: StoredAccountCredentials].self, from: data) else { return [:] }
        return records
    }

    private func save(_ records: [String: StoredAccountCredentials]) {
        Keychain.shared.accountCredentialRecords = try? JSONEncoder().encode(records)
    }
}
