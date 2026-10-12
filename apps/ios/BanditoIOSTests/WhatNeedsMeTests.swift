import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito
@testable import BanditoL10n

/// The line Siri says for "What needs me", in Russian and English (the plurals follow the language's rules).
@Suite struct WhatNeedsMeTests {
    @Test func nothingWaitingSaysSo() {
        L10n.withLanguageForTests("ru") {
            #expect(WhatNeedsMeText.line(pending: 0, waitingNames: [], more: 0) == "Ничего не ждёт")
        }
        L10n.withLanguageForTests("en") {
            #expect(WhatNeedsMeText.line(pending: 0, waitingNames: [], more: 0) == "Nothing needs you")
        }
    }

    @Test func russianPluralsOfTheCount() {
        L10n.withLanguageForTests("ru") {
            #expect(WhatNeedsMeText.line(pending: 1, waitingNames: ["Watch"], more: 0) == "1 ждёт: Watch")
            #expect(WhatNeedsMeText.line(pending: 2, waitingNames: ["Watch", "Forge"], more: 0) == "2 ждут: Watch, Forge")
            #expect(WhatNeedsMeText.line(pending: 5, waitingNames: ["Watch", "Forge"], more: 3)
                == "5 ждут: Watch, Forge и ещё 3")
            #expect(WhatNeedsMeText.line(pending: 21, waitingNames: ["Watch"], more: 0) == "21 ждёт: Watch")
        }
    }

    @Test func englishPluralsOfTheCount() {
        L10n.withLanguageForTests("en") {
            #expect(WhatNeedsMeText.line(pending: 1, waitingNames: ["Watch"], more: 0) == "1 waits: Watch")
            #expect(WhatNeedsMeText.line(pending: 2, waitingNames: ["Watch", "Forge"], more: 0) == "2 wait: Watch, Forge")
        }
    }

    @Test func aCountWithoutNamesSaysHowManyWait() {
        L10n.withLanguageForTests("ru") {
            #expect(WhatNeedsMeText.line(pending: 2, waitingNames: [], more: 0) == "2 ждут вас")
            #expect(WhatNeedsMeText.line(pending: 1, waitingNames: [], more: 0) == "1 ждёт вас")
        }
    }

    @Test func theSnapshotGivesItsWaitingNamesAndTheRest() {
        let watch = WidgetSnapshot.Agent(server: "S1", id: "watch", name: "Watch", status: .needsYou, mood: .needsYou)
        let forge = WidgetSnapshot.Agent(server: "S1", id: "forge", name: "Forge", status: .needsYou, mood: .needsYou)
        let snapshot = WidgetSnapshot(generatedAt: Date(), pending: 5, agents: [], waiting: [watch, forge], waitingCount: 5)
        L10n.withLanguageForTests("ru") {
            #expect(WhatNeedsMeText.line(for: snapshot) == "5 ждут: Watch, Forge и ещё 3")
        }
        L10n.withLanguageForTests("ru") {
            #expect(WhatNeedsMeText.line(for: nil) == "Ничего не ждёт", "no snapshot yet: nothing is known to wait")
        }
    }

    @Test func aFailedAskNamesTheAgentAndSaysWhatToDo() {
        L10n.withLanguageForTests("ru") {
            #expect(AgentAskError.notConnected(name: "Forge").message.contains("Forge"))
            #expect(AgentAskError.failed(name: "Forge").message.contains("Forge"))
            #expect(AgentAskError.empty.message == "Сообщение пустое.")
        }
    }
}
