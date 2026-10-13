# Getting started

The first-run introduction shows instead of the main window while it is not finished and no server is saved on this Mac.
It tells one story with the iPhone app. Its steps are Welcome → What you get → Account → (Approval, only for a new device) →
Server → Who works → Your crew → First task. The step counter reads "Step N of 7" and the line of steps at the bottom shows
where you are. Back (Назад) at the top left always works, and the introduction is saved as you go: if you quit after the
server is connected, it comes back at the step after the server. The introduction can be shown again from the Help menu.

## Welcome

<!-- id: gs-welcome; covers: onboarding:welcome -->
The first screen: the raccoon of points of light assembles, then the title "Your crew is ready" and what Bandito is. Agents run on your own server, on the subscriptions you already have.
Где: Help → Show the introduction again (Показать знакомство снова), or the first launch → Welcome
1. Read the line under the title: agents on Claude Code, Codex and Grok, with roles and schedules, that keep working when the laptop is closed.
2. Click Let's go (Поехали) to see what you get, or the link I already have a server (У меня уже есть сервер) below it, which skips to Server. Back from there returns to Welcome.
3. The language menu at the top right shows the language the interface is in now, in that language (for example Русский). To change it, pick another language; it applies after you restart Bandito.

## What you get

<!-- id: gs-features; covers: onboarding:features -->
Three live cards, not screenshots: A crew, not a chat (the team lineup, each agent with its mood), Nothing risky without you (an approval card you can press: it turns green and asks again), and They work while you sleep (the night shift from 22:00 to 08:00 lighting up its events). Nothing turns by itself, and a card runs its small motion only while it is on screen. Under Reduce Motion the moods stand still and the night shift shows its end state.
Где: Introduction → step 2 of 7 → the cards
1. Turn the cards with the arrow buttons, the ← and → keys, or the dots under the card. Click Approve (Разрешить) on the second card to see how an approval answers.
2. Click Next (Дальше) on the last card to go on, or Skip (Пропустить) under the cards to go straight to Account.

## Account: sign in with GitHub or email

<!-- id: gs-account; covers: onboarding:account -->
Sign-in is optional. The account only syncs your server list, shortcuts and prompts between devices. Code, API keys and conversations stay on your servers.
Где: Introduction → step 3 of 7 → Continue with GitHub (Продолжить с GitHub), or with email → Send code (Прислать код)
1. To sign in with GitHub, click Continue with GitHub. Click Copy code and open GitHub (Скопировать код и открыть GitHub), paste the code on github.com/login/device, and confirm. Bandito waits for the confirmation.
2. To sign in with email, type the address in Email (Почта) and click Send code (Прислать код). Enter the 6-digit code from the letter, one digit per box (Digit 1 of 6 … Digit 6 of 6). The code is checked automatically when it is complete.
3. If the code did not arrive, wait for the countdown (Send a new code in N s) and click Send a new code (Прислать новый код). Use another email (Другая почта) to change the address.
4. To go on without an account, click Continue without an account (Продолжить без аккаунта). Everything stays on this Mac.
5. If the sign-in fails, the message says so: the code expired, the GitHub sign-in was declined, or the device key could not be read. Click Try again (Ещё раз).
## Device approval

<!-- id: gs-approval; covers: onboarding:approval -->
After a sign-in, a Mac that no other device has approved yet waits on this step: Confirm this Mac on another device. Open Bandito on another Mac or iPhone, where a request appears. Compare the code shown there with the one here. If you have no other device, choose I don't have another device to restore sync instead.
Где: Introduction → step 3 of 7 (Account) → Approval
1. On the other device, check the code: They match (They match) means it is this Mac; They differ (They differ) means reject.
2. Approve the request on the other device, or reject it.
## Server step

<!-- id: gs-server; covers: onboarding:server -->
The step where your crew lives: Where your crew lives (Где живёт команда). You choose On this Mac (recommended: quick, with the install shown step by step) or On your own server. On this Mac, Bandito runs the daemon here. On your own server, type its address and click Connect (Connect). Bandito shows the server's fingerprint and asks you to trust it once (This is my server — trust it). It then installs what is missing (On the server) and shows the server as connected. Next: who does the work goes on. An error says in plain words what happened and what to do next.
Где: Introduction → step 4 of 7 → On this Mac or On your own server
1. Pick the server and, for your own server, type the address and click Connect.
2. Compare the fingerprint with the one your server shows, then click This is my server — trust it. If you are not sure, cancel: nothing is trusted until you confirm.
3. Wait for the install to end, then click Next: who does the work (Далее: кто будет работать).
4. If the connection fails (a wrong address, no answer, a key the server does not accept), the title says The connection failed (Подключение не удалось) and What to do (Что сделать) names the fix. Retry (Повторить) tries again; Back (Назад) returns to the address.

## This Mac is your first server

<!-- id: gs-this-mac; covers: -->
Choosing On this Mac adds a server named after this Mac (the name in System Settings, or "This Mac"). No SSH is involved: Bandito is copied to `~/.local/bin`, its service starts, and the app pairs with it over the connection on this Mac, with its own device token. If the daemon does not start, the install log shows the last lines of its log. Agents and their CLIs run on this Mac. Other servers are listed in Settings → Servers.
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
Где: Server (⌘7) → Overview (Обзор) → the Capabilities card (Capabilities) → Install (Установить)
1. Open the Server mode with ⌘7 and stay on Overview.
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
## Who works

<!-- id: gs-runtimes; covers: onboarding:runtimes -->
The step that finds Claude Code, Codex and Grok on the server and lists where each one stands: signed in (with its plan), installed but not signed in, or not installed. Agents run on the official programs of your subscriptions, so at least one must be ready to go on. The others can wait.
Где: Introduction → step 5 of 7 (Who works) → Install (Установить), Sign in (Войти)
1. Click Install (Установить) for a program the server does not have yet. The row shows the install's last line. For one Bandito cannot install (Grok), How to install (Как установить) opens the vendor's guide.
2. Click Sign in (Войти) and finish the login in the terminal that opens. For a program the server cannot check (Grok), click Done (Готово) once you have signed in. Check again (Проверить снова) reads the state again.
3. Continue (Дальше) turns on as soon as one program is installed and signed in.

## Hire your first crew

<!-- id: gs-crew; covers: onboarding:team -->
The step where the crew is made. On the left are the ready teams (Web project, Server on duty, Morning summary, Documentation) and Just one agent (Один агент). On the right is a preview of the choice before anything is made: who joins and what each may use, the model they start on, the schedules in words (all off until you switch one on), the project folder, and the runtime when more than one is signed in. One tap on Hire the crew (Нанять команду) makes it. If something fails halfway, the same button makes only the missing agents, in the same folder, and the folder is made once: nothing is doubled. The agents made are listed, and Give them a task (Дать первую задачу) goes on.
Где: Introduction → step 6 of 7 (Your crew) → Hire the crew (Нанять команду)
1. Pick a team. For one agent, pick a role, type a name (the default is the role) and check the folder.
2. Change the project folder with the folder button if you want another one. By default Bandito makes a free folder in `projects` once.
3. Click Hire the crew (Нанять команду) (or Hire the agent (Нанять агента)). A message that names how many are ready asks you to press the button again after a failure. If you come back to this step (or reopen the app) and some of the team is already on the server, the step shows them as made: Hire the rest (Нанять остальных) makes the missing ones, or Go on with these (Идти дальше с этими) skips them. For one agent you also choose Where it runs (Где работает): on the server itself, or in a separate container (when Docker is on the server).

## First task

<!-- id: gs-task; covers: onboarding:task -->
The last step. Four suggestions are written for the crew you hired, for example Look around this project and tell me what it does, or Check the server's disk and updates. Pick one or write your own. Send to the first agent (Отправить) sends it and opens that agent's chat with the reply already coming in: the introduction ends inside a working conversation. If the send fails, nothing was started, and you can try again: Bandito reads the agent's thread from the server first, so a message that did arrive is not sent twice. Without an agent (you skipped the crew), the step offers Choose a crew (Выбрать команду) to go back.
Где: Introduction → step 7 of 7 (First task) → Send (Отправить)
1. Click a suggestion, or type a task in the field.
2. Click the send button at the bottom right. The chat opens.
3. To look around first, click Open the chat, I will write later (Открыть чат, напишу позже).

## Notifications: asked when they matter

<!-- id: gs-notify-ask; covers: -->
The first-run notice about anonymous statistics does not cover your first chat either: it waits until the first reply is complete and the field is empty, or the next launch. Bandito does not ask for notifications up front. The first time an agent waits for you or finishes a turn, it asks once: Want to know when Forge needs you? Yes, notify me (Да, уведомлять) asks the system; Not now (Не сейчас) leaves it. You can change this in Settings → Notifications.
Где: Main window → the question at the first approval or finished turn
1. Answer Yes, notify me or Not now.

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
