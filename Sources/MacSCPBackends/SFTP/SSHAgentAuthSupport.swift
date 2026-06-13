// SSHAgentAuthSupport.swift — ssh-agent authentication via Traversio SSHAgentClient.
//
// Reads identities from SSH_AUTH_SOCK and returns a Traversio auth method.
// Citadel does not support agent auth directly; SessionCoordinator picks Traversio.

import Foundation
import MacSCPCore
import Traversio

enum SSHAgentAuthSupport {
    static func traversioAuthentication() async throws -> SSHAuthenticationMethod {
        let agent = try SSHAgentClient()
        guard let identity = try await agent.identities().first else {
            throw BackendError.authenticationFailed("No identities in SSH agent")
        }
        return agent.authenticationMethod(for: identity)
    }
}
