# Getting started

The first-run introduction shows instead of the main window while it is not finished and no server has an agent yet.
Its steps are Welcome → Account → (Approval, only for a new device) → Server → First agent → Done. The step counter reads
"Step N of 5". The introduction can be shown again from the Help menu.

## Welcome

<!-- id: gs-welcome; covers: onboarding:welcome -->
The first screen: what Bandito is. Agents run on your own server, on the subscriptions you already have.
Где: Help → Show the introduction again (Показать знакомство снова), or the first launch → Welcome
1. Read the four points on the screen (agents work while the Mac is closed, they ask before risky steps, the server is at hand, the subscriptions are yours).
2. Click Get started — takes 3 minutes to go to Account, or I already have an account (У меня есть аккаунт), which goes to the same step.
3. The language menu at the top right shows the language the interface is in now, in that language (for example Русский). To change it, pick another language; it applies after you restart Bandito.

## Account: sign in with GitHub or email

<!-- id: gs-account; covers: onboarding:account -->
Sign-in is optional. The account only syncs your server list, shortcuts and prompts between devices. Code, API keys and conversations stay on your servers.
Где: Introduction → step 2 of 5 → Continue with GitHub (Продолжить с GitHub), or with email → Send code (Прислать код)
1. To sign in with GitHub, click Continue with GitHub. Click Copy code and open GitHub (Скопировать код и открыть GitHub), paste the code on github.com/login/device, and confirm. Bandito waits for the confirmation.
2. To sign in with email, type the address in Email (Почта) and click Send code (Прислать код). Enter the 6-digit code from the letter, one digit per box (Digit 1 of 6 … Digit 6 of 6). The code is checked automatically when it is complete.
3. If the code did not arrive, wait for the countdown (Send a new code in N s) and click Send a new code (Прислать новый код). Use another email (Другая почта) to change the address.
4. To go on without an account, click Continue without an account (Продолжить без аккаунта). Everything stays on this Mac.
5. If the sign-in fails, the message says so: the code expired, the GitHub sign-in was declined, or the device key could not be read. Click Try again (Ещё раз).
## Device approval

<!-- id: gs-approval; covers: onboarding:approval -->
After a sign-in, a Mac that no other device has approved yet waits on this step: Confirm this Mac on another device. Open Bandito on another Mac or iPhone, where a request appears. Compare the code shown there with the one here. If you have no other device, choose I don't have another device to restore sync instead.
Где: Introduction → step 2 of 5 (Account) → Approval
1. On the other device, check the code: They match (They match) means it is this Mac; They differ (They differ) means reject.
2. Approve the request on the other device, or reject it.
## Server step

<!-- id: gs-server; covers: onboarding:server -->
The step where your team lives: Where will your team live? You choose On this Mac or On your own server. On this Mac, Bandito runs the daemon here. On your own server, type its address and click Connect (Connect). Bandito shows the server's fingerprint and asks you to trust it once (This is my server — trust it). It then installs what is missing (On the server) and shows the server as connected. Next: the first agent goes on.
Где: Introduction → step 3 of 5 → On this Mac or On your own server
1. Pick the server and, for your own server, type the address and click Connect.
2. Compare the fingerprint with the one your server shows, then click This is my server — trust it. If you are not sure, cancel: nothing is trusted until you confirm.
3. Wait for the install to end, then click Next: the first agent.

## This Mac is your first server

<!-- id: gs-this-mac; covers: -->
Choosing On this Mac adds a server named after this Mac (its host name, or "This Mac"). No SSH is involved: Bandito is copied to `~/.local/bin`, its service starts, and the app pairs with it over the connection on this Mac, with its own device token. If the daemon does not start, the install log shows the last lines of its log. Agents and their CLIs run on this Mac. Other servers are listed in Settings → Servers.
Где: Settings (⌘,) → Servers (Серверы) → the server list
1. Open Settings with ⌘, and choose Servers (Серверы). Your Mac is listed with its state: Online (В сети) or Offline (Не в сети).
## Add a server

<!-- id: gs-add-server; covers: sheet:addServer -->
The Add server sheet is the same server step as in the introduction, without the step bar. Choose On your own server, type the address, trust the fingerprint, and the server is added and selected. The sheet then closes by itself. Close (Закрыть) leaves the sheet without adding anything.
Где: Settings (⌘,) → Servers (Серверы) → Add server (Добавить сервер)
1. Click Add server (Добавить сервер). The sheet opens on the server step.
2. Choose On your own server, type the address and click Connect.
3. Trust the fingerprint. When the server is connected, the sheet closes.
## Trust the server's host key (SSH)

<!-- id: gs-host-key; covers: -->
When a server is added over SSH, Bandito shows its host key fingerprint and asks you to trust it once before it connects. If the key of a known server changes, Bandito says so and trusts nothing until you check the server.
Где: Introduction → Server step, or Settings (⌘,) → Servers (Серверы) → Add server (Добавить сервер)
1. Compare the fingerprint with the one on the server. Trust it only if it is yours.
2. If the key changed, check the server first. Bandito does not connect in the meantime.

## Install the components on the server (Установка компонентов)

<!-- id: gs-components; covers: -->
Agents need the Claude Code, Codex or Grok CLI on the server, plus Chrome for the browser and Docker or Podman for containers. Bandito lists what is missing and installs it from the Server mode. Some installs need an administrator password (sudo): the app does not ask for it. It shows the exact command to run in a Bandito terminal, where you type the password yourself.
Где: Server (⌘6) → Overview (Обзор) → the Capabilities card (Capabilities) → Install (Установить)
1. Open the Server mode with ⌘6 and stay on Overview.
2. In Capabilities, see which items are Not installed (Не установлен) and which are Ready (Готово).
3. Click Install (Установить). The log shows the progress. Installs that need the administrator password stop with the message "An administrator password is needed".
4. Click Open terminal (Открыть терминал). A terminal opens with the command typed in. Type the password there. Nothing is typed for you.
5. When the install ends, the item shows Ready (Готово). If it fails, the message reads "Could not install …" and points to the log above.

## Subscriptions of agents

<!-- id: gs-subscriptions; covers: -->
Agents run on the official CLIs and your existing subscriptions. Bandito does not hold new accounts. Log in to each CLI on the server once, in its own terminal: `claude`, `codex login`, or the Grok CLI login. The New agent sheet shows the state of each runtime: Signed in · N% left, Not signed in on the server, or Not installed on the server.
Где: Team (⌘1) → New agent (⌘N) → Powered by (Чем думает)
1. Open New agent with ⌘N.
2. Read the state under each runtime. Runtimes that are not ready are shown with the reason. Run the command the sheet names on the server, for example `codex login`.
## First agent (Первый агент)

<!-- id: gs-first-agent; covers: onboarding:agent -->
The first-agent step creates your first agent: a template or a blank one, a name, a runtime that is signed in on the server, a project folder and the workplace (Shared). Connect your subscriptions shows which runtimes are ready and what to do with the others. The agent is created with the same options as in New agent (see [new-agent.md](new-agent.md)).
Где: Introduction → step 4 of 5 (Agent)
1. Pick a runtime that is signed in, type a name and click Next to finish the step.
2. Create more agents later with New agent (⌘N).
## Tour: your first look

<!-- id: gs-tour; covers: -->
After the first agent, a short tour starts over the main window: a dimmed layer with a bubble that points at one part of the screen after another, for example Your agents and Files and terminals. Skip ends it at any step. A step whose part is not on screen is left out.
Где: Introduction → last step of the first agent
1. Read the bubble and go on, or skip the tour.

## Skip the introduction

<!-- id: gs-skip; covers: -->
From any step after Welcome, Skip (Пропустить) opens the main window and the introduction does not show again on launch. You can still set up everything from Settings.
Где: Introduction → top right → Skip (Пропустить)
1. Click Skip (Пропустить). The main window opens.

## Done (Готово)

<!-- id: gs-done; covers: onboarding:done -->
The last step of the flow. Reaching it stores that the introduction is done, and the main window takes over. It has no screen of its own.
Где: Introduction → after the last step
1. Finish the steps, or click Skip (Пропустить). The main window opens.

## Show the introduction again

<!-- id: gs-replay; covers: -->
Starts the introduction from Welcome whatever the server state is.
Где: Help → Show the introduction again (Показать знакомство снова)
1. Open the Help menu and choose Show the introduction again (Показать знакомство снова).
