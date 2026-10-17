import Foundation
import PosternModel
import PosternVault

/// Loads and saves the policy. Anything unreadable falls back to `Policy.initial`: Postern fails closed.
public struct PolicyStore: Sendable {
    private let vault: any SecretStore

    public init(vault: any SecretStore) {
        self.vault = vault
    }

    public func load() -> Policy {
        (try? vault.read(.policy, as: Policy.self)) ?? .initial
    }

    public func save(_ policy: Policy) throws {
        try vault.write(policy, for: .policy)
    }
}
