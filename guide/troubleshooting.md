# Troubleshooting

Common messages and what to do with them. Each entry starts with the exact text the app shows (English, as in
`i18n/en.json`), then the Russian text in brackets, then the steps. Where a message has a placeholder such as
{name}, the entry shows it as {name}.
## SSH: host key and connection errors

<!-- id: ts-ssh; covers: -->
When a server does not connect over SSH, the server step says why. A host this Mac has not seen before asks for its fingerprint to be checked. A changed key is refused: nothing is trusted until you check the server. A refused or timed-out connection means SSH is not running on that port or the server is not reachable.
Где: Settings (⌘,) → Servers (Серверы) → Add server (Добавить сервер)
1. Check the fingerprint, or the server's address and port, then click Try again (Try again).
2. For a refused or timed-out connection, check that SSH runs on the server and that the server is on and reachable.

## Connecting to the server… (Подключаемся к серверу…)

<!-- id: ts-connecting; covers: -->
The app is still reaching the server, or the server is not reachable. Team agents show Offline (Не в сети) while it is down.
Где: Any mode → the page message; Team → agent row → status Offline (Не в сети)
1. Wait a few seconds: the app connects again on its own.
2. If it stays, click Retry (Повторить) on the banner.
3. Check the server itself: a Mac server must be on and awake; a remote server must run the Bandito daemon.
4. Read the daemon log in a terminal on the server if you need the reason (see [server.md](server.md)).

## No server selected (Сервер не выбран)

<!-- id: ts-no-server; covers: -->
Terminals and other server modes need a selected server.
Где: Top bar → server picker
1. Pick a server in the top bar. If the list is empty, the server was removed (see [settings.md](settings.md)).

## This server runs an older Bandito. Update it to see this.

<!-- id: ts-old-server; covers: -->
Some screens need a newer daemon on the server. They show this note instead of the feature. Also seen as Update the server (Обновите сервер), Update the server to use terminals and The browser appears after the server is updated (The browser appears after the server is updated).
Где: Server → Updates (Обновления); the screen with the note
1. Open Server → Updates (Обновления) and click Open in terminal (Открыть в терминале) under How to update (Как обновить).
2. Run the install script in the terminal. It keeps your data and settings.

## An administrator password is needed

<!-- id: ts-sudo; covers: -->
An install needs the administrator password (sudo). Bandito never asks for it inside the app. The message says: An administrator password is needed. Run the command in a Bandito terminal and type the password there.
Где: Server → Overview → Capabilities (Возможности) → message under the install log
1. Click Open terminal (Открыть терминал). The command is typed in the terminal.
2. Type the password in that terminal and press ↵. The install goes on.

## Could not install {component}. See the log above.

<!-- id: ts-install-failed; covers: -->
An install of a component failed. The log shows why.
Где: Server → Overview → Capabilities (Возможности) → log
1. Read the last lines of the log above the message.
2. Fix the cause (for example, free disk space, or run the command by hand in a terminal), then click Install (Установить) again.

## Chrome is needed for the browser (Для браузера нужен Chrome)

<!-- id: ts-chrome; covers: -->
The browser needs Google Chrome on the server. The Browser mode shows the message and the Install (Установить) button.
Где: Browser → message
1. Click Install (Установить). Wait for Installing… this can take a few minutes.
2. If it fails: The install did not finish. See the server log. Read the log, then try again.

## The browser is not running (Браузер не запущен)

<!-- id: ts-browser-stopped; covers: -->
The Browser mode is open, but the browser on the server is not started.
Где: Browser → message → Start browser (Запустить браузер)
1. Click Start browser (Запустить браузер).

## Could not reach the browser (Не удалось подключиться к браузеру)

<!-- id: ts-browser-error; covers: -->
The app cannot reach the browser on the server.
Где: Browser → message → Retry (Повторить)
1. Click Retry (Повторить). If it fails again, check that the server is online.

## The preview did not load (Превью не загрузилось)

<!-- id: ts-preview; covers: -->
The page of a server port did not open. The agent's web server may not be running.
Где: Browser → Preview (Превью)
1. Check that the server process is running (Server → Ports (Порты)).
2. Open the port again with Open (Открыть).

## Could not connect to the screen (Не удалось подключиться к экрану)

<!-- id: ts-screen-error; covers: -->
The server screen cannot be reached. Also seen as The screen is asleep (Экран спит).
Где: Server screen → message
1. If the screen is asleep, click Start screen (Запустить экран).
2. If it fails, check the server is online and on Linux (see [screen.md](screen.md)).

## The server screen is available on Linux servers (The server screen is available on Linux servers)

<!-- id: ts-screen-unsupported; covers: -->
The server is not a Linux desktop, so the screen cannot be shown.
Где: Server screen → message
1. Use Terminals or the Browser instead (see [terminals.md](terminals.md) and [browser.md](browser.md)).

## Could not open a terminal: {message} (Could not open a terminal: {message})

<!-- id: ts-terminal-new; covers: -->
A new terminal could not start on the server.
Где: Terminals → message
1. Read the message after the colon, then click Retry (Повторить).
2. If the message says the server is old, see "This server runs an older Bandito" above.

## No room on screen. Collapse or close a pane first.

<!-- id: ts-no-room; covers: -->
The layout is full. A new pane needs room.
Где: Terminals → Split (Разделить)
1. Collapse a pane (⌘⇧↓) into the dock, or close one (⌘W). Then split again.

## Process ended (code N) (Process ended (code {code}))

<!-- id: ts-process-ended; covers: -->
The shell or the command in a pane has stopped. The number is the exit code, or a signal name for Process ended (signal …).
Где: Terminals → pane → Restart (Перезапустить)
1. Read the output above. Click Restart (Перезапустить) to start the shell again in the same folder.

## Usage limit reached. Resets at {time}.

<!-- id: ts-limit; covers: -->
The subscription of the agent's runtime has no quota left. The agent waits for the reset or uses the fallback.
Где: Team → agent thread → banner; Settings (⌘,) → Subscriptions and limits (Подписки и лимиты); Agent details → Details → If the limit runs out (Если лимит кончится)
1. Read the reset time. Wait for it, or set a fallback runtime in the agent's details.
2. Check the bars in Settings → Subscriptions and limits. Click Refresh (Обновить) for the latest numbers.
3. On the agent card of New agent, the state Limit used up · again {time} (Limit used up · again {time}) shows the same.

## No limits received yet

<!-- id: ts-no-limits; covers: -->
The app has not received the subscription limits from the server yet.
Где: Settings (⌘,) → Subscriptions and limits (Подписки и лимиты)
1. Send a message to the agent (the limits come after the first reply), or click Refresh (Обновить).

## {runtime} is not logged in on {server}.

<!-- id: ts-not-logged-in; covers: -->
The CLI of the runtime is installed on the server but not signed in. The full text says: Run `{command}` there.
Где: New agent sheet → Powered by (Чем думает) → runtime state Not signed in on the server (Вход на сервере не выполнен); Agent details → Where it runs (Где работает)
1. Open a terminal on the server (Terminals mode, ⌘T) and run the command the message names, for example `codex login`.
2. Complete the sign-in in the CLI. Then the state changes to Signed in.

## Not installed on the server (Не установлен на сервере)

<!-- id: ts-not-installed; covers: -->
The runtime's CLI is not on the server.
Где: New agent sheet → Powered by (Чем думает); Server → Overview → Capabilities (Возможности)
1. Click Install (Установить) on the Capabilities card, or install the CLI by hand in a terminal on the server.

## Pausing needs a newer server (Пауза требует более новой версии сервера)

<!-- id: ts-pause; covers: -->
Pausing an agent needs a server method that is not in this build yet.
Где: Team → sidebar → agent menu → Pause (Приостановить)
1. Use Stop agent (⌘.) instead. Update the server when a newer version is out.

## Could not answer: the request is already answered or out of date

<!-- id: ts-approval-late; covers: -->
You tried to answer an approval that is already answered, or that expired (approvals expire after 24 hours and are denied).
Где: Team → approval card; menu bar notification
1. Look at the agent thread. The card shows Allowed by you · just now (Allowed by you · just now) or Denied by a rule (Запрещено правилом) when it was answered.
2. If the agent is still waiting for a new step, it will ask again.

## Could not send your answer: {error} (Could not send your answer: {error})

<!-- id: ts-menubar-answer; covers: -->
The answer from the menu bar could not reach the server.
Где: Menu bar → agent row → Approve (Разрешить) or Deny (Отклонить)
1. Open Bandito and answer in the agent thread.

## This agent no longer exists (Агент не найден)

<!-- id: ts-agent-gone; covers: -->
An agent was deleted, but a view still points to it.
Где: Team → What changed (Что изменил агент)
1. Pick another agent in the sidebar.

## The file changed on the server (The file changed on the server while you were editing it)

<!-- id: ts-file-conflict; covers: -->
Someone or an agent saved the file while you edit it.
Где: Files → viewer → message
1. Click Show difference (Показать разницу), then choose Keep mine (Оставить мой) or Take the server’s (Взять с сервера).

## A file with this name already exists (“…” is already here)

<!-- id: ts-file-exists; covers: -->
A file with the same name is in the folder.
Где: Files → name dialog
1. Click Replace (Заменить), Keep both (Оставить оба), or Cancel (Отмена).

## Files: No permission, This no longer exists on the server (No permission)

<!-- id: ts-files-errors; covers: -->
Other file errors: This no longer exists on the server (Этого больше нет на сервере), No permission (Нет доступа), The file is too large (Файл слишком большой), Outside the allowed folders (Вне разрешённых папок), Invalid path (Некорректный путь), Disk error (Ошибка диска), Not a folder (Это не папка), This is a folder (Это папка), Not a regular file (Это не обычный файл).
Где: Files → message
1. No permission: the server user cannot read or change the item. Ask the server admin, or work in a folder you own.
2. This no longer exists on the server: refresh the folder; the item was moved or deleted.
3. Outside the allowed folders: Files only show the folders the server allows. Use Projects (Проекты) or Home (Домашняя).
4. Disk error: free disk space on the server.

## Could not download: {error} (Could not download: {error})

<!-- id: ts-download; covers: -->
A file could not be copied to this Mac.
Где: Files → Download to Mac (Скачать на Mac)
1. Read the error after the colon, then try again.

## Could not change the login item: {error} (Could not change the login item: {error})

<!-- id: ts-login-item; covers: -->
Launch at login could not be switched on or off.
Где: Settings (⌘,) → General (Общие) → Launch at login (Запускать при входе в систему)
1. Turn the switch on or off in System Settings → General → Login Items if the switch keeps going back.

## Sign-in does not start: Could not start sign-in. Try again.

<!-- id: ts-signin; covers: -->
The sign-in could not begin, or the device key could not be read. Other sign-in messages: Something went wrong. Try again., The code has expired. Start again., You declined the sign-in on GitHub., Enter a valid email address.
Где: First-run introduction → Account (Аккаунт)
1. Click Try again (Ещё раз) or Send a new code (Прислать новый код).
2. Check the internet connection. If it keeps failing, continue without an account and sign in later.

## Pair a device: the code is not accepted (The code works once.)

<!-- id: ts-pair; covers: -->
A pairing code works once and is valid for a few minutes.
Где: Server → Devices (Устройства) → Add device (Добавить устройство)
1. Click Add device (Добавить устройство) again to get a new code, and enter it on the device.

## Shortcut is taken (taken by: {name})

<!-- id: ts-shortcut; covers: -->
Two commands in the same context cannot use the same keys.
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Keys (Клавиши)
1. Click Replace (Заменить) to move the shortcut, or pick other keys.

## The Keys row says the change has no effect (planned)

<!-- id: ts-screen-keys; covers: ; status: planned -->
The shortcuts Take / give back control and Send the key combination to the server are listed in Settings, but changing them does nothing yet: the screen keeps its fixed keys (⇧⌘C and ⌃⌥⌫).
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Keys (Клавиши) → Server screen (Экран сервера)
1. Use the fixed keys in the Server screen mode.
