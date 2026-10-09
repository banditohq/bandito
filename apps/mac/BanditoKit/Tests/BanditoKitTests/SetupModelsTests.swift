import Foundation
import Testing

@testable import BanditoKit

@Suite struct SetupModelsTests {
    @Test func decodesStatusFromTheDaemonWireFormat() throws {
        let json = """
            {"os":"linux","arch":"x86_64","package_manager":"apt","sudo":"password",
             "components":[{"id":"xvfb","feature":"screen","installed":false,"version":null,
               "installable":true,"needs_sudo":true,"hint":null},
              {"id":"docker","feature":"containers","installed":false,"version":null,
               "installable":false,"needs_sudo":false,"hint":"Install Docker"}],
             "features":{"screen":"missing","browser":"ready","containers":"unsupported",
               "agents":{"claude":"ready","codex":"missing","grok":"missing"}}}
            """
        let status = try RPCClient.decoder.decode(SetupStatus.self, from: Data(json.utf8))
        #expect(status.sudo == .password)
        #expect(status.packageManager == "apt")
        #expect(status.components.map(\.id) == ["xvfb", "docker"])
        #expect(status.components[0].feature == .screen)
        #expect(status.components[0].needsSudo)
        #expect(status.components[1].hint == "Install Docker")
        #expect(status.features.screen == .missing)
        #expect(status.features.containers == .unsupported)
        #expect(status.features.agents.claude == .ready)
        #expect(status.features.agents.grok == .missing)
    }

    @Test func unknownValuesFallBackInsteadOfFailing() throws {
        let json = """
            {"os":"macos","arch":"arm64","package_manager":null,"sudo":"sometime",
             "components":[{"id":"x","feature":"telepathy","installed":true,"version":"1",
               "installable":false,"needs_sudo":false,"hint":null}],
             "features":{"screen":"ready","browser":"ready","containers":"ready",
               "agents":{"claude":"ready","codex":"ready","grok":"ready"}}}
            """
        let status = try RPCClient.decoder.decode(SetupStatus.self, from: Data(json.utf8))
        #expect(status.sudo == .none)
        #expect(status.packageManager == nil)
        #expect(status.components[0].feature == .agents)
    }

    @Test func decodesJobWithPasswordPrompt() throws {
        let json = #"{"state":"needs_password","step":"System packages","log":"","offset":42,"command":"sudo apt-get install -y xvfb"}"#
        let job = try RPCClient.decoder.decode(SetupJob.self, from: Data(json.utf8))
        #expect(job.state == .needsPassword)
        #expect(job.offset == 42)
        #expect(job.command == "sudo apt-get install -y xvfb")
        #expect(job.failedComponent == nil)
    }

    @Test func decodesFailedJobWithComponent() throws {
        let json = #"{"state":"failed","step":"Chrome","log":"E: Unable to locate","offset":9,"failed_component":"browser"}"#
        let job = try RPCClient.decoder.decode(SetupJob.self, from: Data(json.utf8))
        #expect(job.state == .failed)
        #expect(job.failedComponent == "browser")
    }

    @Test func installReplyCarriesTheJobId() throws {
        let reply = try RPCClient.decoder.decode(SetupInstallReply.self, from: Data(#"{"job_id":"j1"}"#.utf8))
        #expect(reply.jobId == "j1")
    }
}
