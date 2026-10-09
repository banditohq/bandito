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

<!-- id: gs-approval; covers: onboarding:approval; status: planned -->
After a sign-in, a device that is not approved yet should go to this step. In this build the step is a placeholder: its title is Coming soon (Скоро здесь) and the only control is Next (Дальше). Approval by code is not in the app yet.
Где: Introduction → step 2 of 5 (Account) → Approval → Next (Дальше)
1. Click Next (Дальше) to go on to the server step.
2. Until device approval ships, a signed-in device is not blocked by this step.

## Server step

<!-- id: gs-server; covers: onboarding:server; status: planned -->
This step is meant to choose where the team lives. In this build it is a placeholder: the title Where will your team live? (Где будет жить ваша команда?) and Next (Дальше). A Mac is connected as a server automatically (see "This Mac is your first server" below). Connecting a remote server over SSH is not in the app yet.
Где: Introduction → step 3 of 5 → Next (Дальше)
1. Click Next (Дальше) to go to the first agent step.

## This Mac is your first server

<!-- id: gs-this-mac; covers: -->
On the first launch Bandito adds a server named after this Mac (the host name, or "This Mac"). It runs the Bandito daemon on this Mac, so agents and their CLIs run here. Other servers are listed in Settings → Servers.
Где: Settings (⌘,) → Servers (Серверы) → the server list
1. Open Settings with ⌘, and choose Servers (Серверы). Your Mac is listed with its state: Online (В сети) or Offline (Не в сети).

## Add a server: SSH, Tailscale, pairing code

<!-- id: gs-add-server; covers: sheet:addServer; status: planned -->
The Add server wizard (SSH with ~/.ssh/config, Tailscale, or a pairing code) is not connected in this build. The button opens a sheet that says Coming soon (Скоро здесь) and a Close (Закрыть) button. Use this Mac or a server that is already set up.
Где: Settings (⌘,) → Servers (Серверы) → Add server (Добавить сервер)
1. Click Add server (Добавить сервер). The sheet opens and says Coming soon (Скоро здесь).
2. Click Close (Закрыть).

## Trust the server's host key (SSH) (planned)

<!-- id: gs-host-key; covers: ; status: planned -->
When a server is added over SSH, Bandito should show the server's host key fingerprint and ask you to trust it once before it connects. The check and the question are not in this build, because the SSH wizard is not connected yet.
Где: Settings (⌘,) → Servers (Серверы) → Add server (Добавить сервер) → SSH (SSH)
1. Nothing to confirm yet. This Mac needs no host key.

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

<!-- id: gs-first-agent; covers: onboarding:agent; status: planned -->
The first-agent step of the introduction is a placeholder in this build (Coming soon). Create the first agent with New agent (⌘N): see [new-agent.md](new-agent.md).
Где: Introduction → step 4 of 5 → Next (Дальше)
1. Click Next (Дальше). Create the agent later with ⌘N.

## Tour: How it works (Как пользоваться)

<!-- id: gs-tour; covers: ; status: planned -->
The tour has four cards (This is your team; Write to it like a colleague; Risky things need your yes; See what's left). It is not in the flow in this build: the step bar shows the label How it works (Как пользоваться), but there is no screen for it. Read [team.md](team.md) and [security.md](security.md) instead.
Где: Introduction → step bar → How it works (Как пользоваться)
1. Nothing to click yet. Use this guide.

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
