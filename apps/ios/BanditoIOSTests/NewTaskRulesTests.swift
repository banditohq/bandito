import AVFoundation
import BanditoKit
import Foundation
import Speech
import SwiftUI
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The rules of the new-task sheet: the agents it offers and their order, the send rule, the last agent used, and when
/// the microphone is offered.
@MainActor
@Suite struct NewTaskRulesTests {
    private func option(_ server: UUID, _ agent: String, paused: Bool = false) -> NewTaskOption {
        NewTaskOption(
            serverID: server, serverName: "Mac", agentID: agent, agentName: agent,
            look: CrewLook(color: .peach, face: .sleeping, customHex: nil), mood: .idle, paused: paused)
    }

    @Test func theLastAgentUsedComesFirst() {
        let first = UUID()
        let second = UUID()
        let options = [option(first, "a"), option(first, "b"), option(second, "c")]
        let ordered = NewTaskRules.order(options, last: NewTaskChoice(serverID: first, agentID: "b"))
        #expect(ordered.map(\.agentID) == ["b", "a", "c"])
    }

    @Test func aLastAgentThatIsGoneLeavesTheUsualOrder() {
        let first = UUID()
        let second = UUID()
        let options = [option(first, "a"), option(first, "b"), option(second, "c")]
        let ordered = NewTaskRules.order(options, last: NewTaskChoice(serverID: second, agentID: "removed"))
        #expect(ordered.map(\.agentID) == ["a", "b", "c"])
        #expect(NewTaskRules.order(options, last: nil).map(\.agentID) == ["a", "b", "c"])
    }

    @Test func pausedAgentsGoToTheEnd() {
        let server = UUID()
        let options = [option(server, "a", paused: true), option(server, "b"), option(server, "c")]
        let ordered = NewTaskRules.order(options, last: nil)
        #expect(ordered.map(\.agentID) == ["b", "c", "a"])
    }

    @Test func aPausedLastAgentStaysAtTheEnd() {
        let server = UUID()
        let options = [option(server, "a"), option(server, "b", paused: true), option(server, "c")]
        let ordered = NewTaskRules.order(options, last: NewTaskChoice(serverID: server, agentID: "b"))
        #expect(ordered.map(\.agentID) == ["a", "c", "b"])
    }

    @Test func emptyTextCannotBeSent() {
        #expect(!NewTaskRules.canSend(text: "", agentChosen: true))
    }

    @Test func blankTextCannotBeSent() {
        #expect(!NewTaskRules.canSend(text: "   \n\t ", agentChosen: true))
    }

    @Test func aTaskNeedsAnAgent() {
        #expect(!NewTaskRules.canSend(text: "fix the build", agentChosen: false))
        #expect(NewTaskRules.canSend(text: "fix the build", agentChosen: true))
    }

    @Test func theMessageIsSentTrimmed() {
        #expect(NewTaskRules.message(for: "  check the logs \n") == "check the logs")
    }

    @Test func noAgentsGivesAnEmptyList() async {
        let server = await IOSDemo.start(withTeam: false)
        #expect(NewTaskRules.options(servers: [server]).isEmpty)
        #expect(NewTaskRules.options(servers: []).isEmpty)
    }

    @Test func theLastChoiceIsRemembered() {
        let suite = "NewTaskRulesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("no defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NewTaskRules.lastChoice(defaults: defaults) == nil)
        let choice = NewTaskChoice(serverID: UUID(), agentID: "forge")
        NewTaskRules.remember(choice, defaults: defaults)
        #expect(NewTaskRules.lastChoice(defaults: defaults) == choice)
    }

    @Test func theMicrophoneIsHiddenWhenRefusedOrUnavailable() {
        #expect(
            NewTaskRules.microphoneShown(speech: .authorized, microphone: .granted, recognizerAvailable: true))
        #expect(
            NewTaskRules.microphoneShown(speech: .notDetermined, microphone: .undetermined, recognizerAvailable: true))
        #expect(
            !NewTaskRules.microphoneShown(speech: .denied, microphone: .granted, recognizerAvailable: true))
        #expect(
            !NewTaskRules.microphoneShown(speech: .authorized, microphone: .denied, recognizerAvailable: true))
        #expect(
            !NewTaskRules.microphoneShown(speech: .authorized, microphone: .granted, recognizerAvailable: false))
    }
}
