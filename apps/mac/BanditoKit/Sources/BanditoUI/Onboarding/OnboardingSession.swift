import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The models of the steps that need the connected server. The flow owns one, so going from a step to the next (or
/// back) does not make the models again: a crew that is half made, or a login terminal, is still there on return.
@MainActor
@Observable
final class OnboardingSession {
    let server: ServerModel
    let subscriptions: SubscriptionsModel
    let crew: CrewModel
    /// The first-task model, made when the step opens for an agent.
    private(set) var task: FirstTaskModel?

    init(server: ServerModel) {
        self.server = server
        let subscriptions = SubscriptionsModel(server: server)
        self.subscriptions = subscriptions
        crew = CrewModel(server: server, subscriptions: subscriptions)
    }

    /// The task model for `agentID`; a new one when the agent changed.
    func taskModel(agentID: String, teamID: String?) -> FirstTaskModel {
        if let task, task.agentID == agentID, task.teamID == teamID { return task }
        let made = FirstTaskModel(server: server, agentID: agentID, teamID: teamID)
        task = made
        return made
    }
}

/// Gives a step that needs a server its session. Without a connected server the step says so and offers the way back
/// to the server step: nothing waits for a server that is not there.
struct OnboardingSessionHost<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(OnboardingModel.self) private var onboarding
    @Binding var session: OnboardingSession?
    @ViewBuilder var content: (OnboardingSession) -> Content

    var body: some View {
        if let server = app.currentServer {
            if let session, session.server.id == server.id {
                content(session)
            } else {
                // One frame of nothing while the session is made: it is state, so it cannot be written while drawing.
                Color.clear.onAppear { session = OnboardingSession(server: server) }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.Onboarding.Crew.noServer)
                    .font(BanditoFont.text(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Button(L10n.Onboarding.Crew.toServer) { onboarding.returnToServer() }
                    .banditoButton(.signal())
                    .fixedSize()
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

/// Step 4 on screen: the runtimes of the server, polled every three seconds while the step is open and the app is the
/// active one. Leaving the step closes a login terminal that is open.
struct RuntimesPane: View {
    var model: SubscriptionsModel
    var onContinue: () -> Void

    var body: some View {
        SubscriptionsStep(model: model) {
            // The login terminal belongs to this step: it closes before the next one opens.
            Task {
                await model.endLogin()
                onContinue()
            }
        }
        .task {
            while !Task.isCancelled {
                if AppActivity.isActive { await model.poll() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear {
            Task { await model.endLogin() }
        }
    }
}
