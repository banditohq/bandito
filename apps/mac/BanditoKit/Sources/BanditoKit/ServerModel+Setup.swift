import Foundation

// Setting the server up for its features: what is missing and installing it (docs/ARCHITECTURE.md#setup).

extension ServerModel {
    public func setupStatus() async throws -> SetupStatus {
        try await rpc().call("setup.status", NoParams(), as: SetupStatus.self)
    }

    /// Starts one install job in the background and returns its id. Another install while one runs fails with `busy`.
    public func setupInstall(components: [String]) async throws -> String {
        struct P: Encodable { var components: [String] }
        return try await rpc().call("setup.install", P(components: components), as: SetupInstallReply.self).jobId
    }

    /// The job's state and the log from byte `offset`. Poll about once a second.
    public func setupJob(_ id: String, from offset: UInt64) async throws -> SetupJob {
        struct P: Encodable { var jobId: String; var from: UInt64 }
        return try await rpc().call("setup.job", P(jobId: id, from: offset), as: SetupJob.self)
    }
}
