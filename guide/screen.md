# Server screen (Экран сервера)

The desktop of the server, shown on this Mac. You can watch an agent work on it, take control to click and type,
and give control back. The screen wakes on demand and sleeps when nobody uses it. Open the mode with ⌘5.

## Server screen mode

<!-- id: screen-mode; covers: mode:screen -->
The main area shows the server's screen. The toolbar has the quality picker, the Ctrl+Alt+Del button, Full screen, and the control button.
Где: Mode bar → Server screen (Экран сервера), or Menu View → Server screen (Экран сервера)
1. Press ⌘5 or click Server screen (Экран сервера) in the mode bar.
2. If the screen is asleep, the page says The screen is asleep (Экран спит). Click Start screen (Запустить экран).
3. While it connects, the page says Connecting to the screen… (Подключаем экран…).

## Take control and give it back (Take / give back control)

<!-- id: screen-take-control; covers: -->
Taking control lets you click and type on the server's screen. While you hold it, the agent waits. Giving it back lets the agent continue.
Где: Server screen → toolbar → Take control (Take / give back control) or Give to agent (Отдать агенту); shortcut ⌘⇧C
1. Press ⌘⇧C, or click Take control (Take / give back control). The status says You are watching (Вы смотрите) or you have control.
2. Click the screen or type. The agent waits until you let go.
3. Click Give to agent (Отдать агенту) to hand the screen back. The status says Agent is controlling (Агент управляет).
4. If an agent is on the screen when you click or type, the hint says The agent is working on the screen. Take control to type. (The agent is working on the screen. Take control to type.) Click Take control to type.
5. The command is fixed in this build: the key combination is set in the screen itself. Changing it in Settings → Keys and gestures has no effect yet (status: planned, see [keys.md](keys.md)).

## Send Ctrl+Alt+Del (Отправить Ctrl+Alt+Del)

<!-- id: screen-cad; covers: -->
Sends the Ctrl+Alt+Del combination to the server's screen, for a login screen that asks for it.
Где: Server screen → toolbar → ⌃⌥⌫ (help: Send Ctrl+Alt+Del)
1. Click the button ⌃⌥⌫ in the toolbar, or press ⌃⌥⌫ while the screen is in front.
2. The combination is sent once. The key combination is fixed in this build and cannot be changed.

## Picture quality (Quality)

<!-- id: screen-quality; covers: -->
Choose between a faster and a sharper picture. Changing the quality reconnects the screen.
Где: Server screen → toolbar → Quality (Качество); Settings → Browser and screen (Браузер и экран) → Picture quality (Качество картинки)
1. Pick Auto (Авто), Faster (Быстрее), or Sharper (Чётче) in the toolbar. The screen reconnects with the new quality.
2. The same choice is in Settings → Browser and screen, and it applies to the browser and the screen both.

## Full screen (На весь экран)

<!-- id: screen-fullscreen; covers: -->
Makes the window of the app take the whole screen. The screen view fills the window.
Где: Server screen → toolbar → Full screen (На весь экран)
1. Click the button Full screen (На весь экран), or use the macOS full screen command for the window.

## Who is here and screens of workplaces (Who is here, Screens of workplaces)

<!-- id: screen-who; covers: -->
The side panel shows who is connected to the screen now, and the screens of the agents' workplaces.
Где: Server screen → side panel → Who is here (Кто здесь), Screens of workplaces (Экраны рабочих мест)
1. Read the names under Who is here (Кто здесь).
2. Under Screens of workplaces (Экраны рабочих мест), every workplace has a card: the shared server (Общий сервер) and each container. A card shows a preview of the last picture, the name, and the state: Screen on (Экран включён), Asleep (Спит), or Not available yet (Пока недоступен). A container that is not running also says so.
3. Click a card to show that workplace's screen in the main area. The choice is kept for the server. Only the chosen screen is connected; the others wake only when you open them.
4. A card says Not available yet (Пока недоступен) when the server's Bandito is too old to show the screen of a separate workplace. Open Server → Updates and update the server.

## Shared clipboard (Clipboard)

<!-- id: screen-clipboard; covers: -->
Copy on this Mac and paste on the server, and the other way round. Set it in the side panel or in Settings.
Где: Server screen → side panel → Transfer (Передача) → Clipboard (Буфер обмена) → Shared (Общее) or Off (Выключены); Settings → Browser and screen (Браузер и экран) → Shared clipboard (Общий буфер обмена)
1. Pick Shared (Общее) to share the clipboard, or Off (Выключены) to turn it off.
2. Copy text here and paste it there. The same switch is in Settings.

## Agent and screen states (Agent is controlling, You are watching)

<!-- id: screen-states; covers: -->
A line under the toolbar shows who holds the screen now. A pale line asks you to take control when you click while an agent is on the screen.
Где: Server screen → status line
1. Agent is controlling (Агент управляет): the agent works on the screen; you watch.
2. Take control to click here? (Take control to click here?): the agent holds the screen and you clicked. Click Take control to act.
3. Shared (Общее): the screen is shared with the workplace of the server.

## Screen sleep (The screen wakes on demand)

<!-- id: screen-sleep; covers: -->
The screen wakes when someone uses it. After 30 minutes without anyone using it, neither you nor the agents, it sleeps again.
Где: Server screen → hint line → The screen wakes on demand. After 30 minutes nobody uses it, neither you nor agents, and it sleeps again.
1. To wake it, click Start screen (Запустить экран).

## Starting the screen (Starting the screen…)

<!-- id: screen-start; covers: -->
While the server starts the screen, the button turns into a spinner with the words Starting the screen… (Запускаем экран…). When the screen runs, the page says Connecting to the screen… (Подключаем экран…) until the first picture comes.
Где: Server screen → page, where the Start screen button was
1. Wait. Do not click again: the spinner means the start is in progress.
2. When the picture arrives, the screen shows. Nothing else to do.

## Programs the server lacks (Install)

<!-- id: screen-missing-components; covers: -->
If the server has no programs the screen needs, the page names them in red, such as The screen needs programs that the server does not have: x11vnc, xdotool. Install (Установить) is under it. Click it and Bandito installs the programs on the server, then starts the screen.
Где: Server screen → page, where the Start screen button was; the button Install (Установить)
1. Click Install (Установить). The page shows the install's progress with its log: Installing the programs the screen needs… (Устанавливаем программы для экрана…).
2. If the server needs an administrator password, the page shows a command. Click Open terminal (Открыть терминал), type the password there, and click Install (Установить) again.
3. When the install is done, the screen starts by itself. If it fails, the page names the program that could not be installed.

## Start failed (Retry)

<!-- id: screen-start-failed; covers: -->
If the screen does not start, the page says why under the icon: a sentence in red, Could not start the screen (Не удалось запустить экран). Retry (Повторить) is under it.
Где: Server screen → page → sentence and Retry (Повторить)
1. Click Retry (Повторить). The app starts the screen again.
2. Details (Подробнее) is a full-width line under the sentence. Click it to open the technical text; it can be copied, for a report.

## Screen did not answer (The screen did not answer)

<!-- id: screen-no-frame; covers: -->
The screen started, but its first picture did not come within 20 seconds. The page says The screen did not answer (Экран не ответил) with Retry (Повторить).
Где: Server screen → page → The screen did not answer (Экран не ответил) and Retry (Повторить)
1. Click Retry (Повторить). The app starts the screen again and connects.
2. If it still does not answer, stop the screen on the server and start it again, or write to support with the server's journal.

## Server needs an update (This server runs an old version of Bandito)

<!-- id: screen-needs-update; covers: -->
On a Linux server with an old daemon the screen is not in its features, so it cannot start. The page says This server runs an old version of Bandito. Update the server to start the screen. (На этом сервере старая версия Bandito — обновите сервер, чтобы запускать экран.) instead of the start button.
Где: Server screen → page, where the start button is; the button Open updates (Открыть обновления)
1. Click Open updates (Открыть обновления). Server → Updates opens.
2. Click Update server (Обновить сервер) there, and come back to the Server screen when it is done.

## Trackpad on the screen (Pinch, Double tap)

<!-- id: screen-gestures; covers: -->
Pinch zooms the screen; a two-finger double tap zooms in on the place you tap.
Где: Server screen → trackpad; Settings → Keys and gestures (Клавиши и жесты) → Trackpad gestures (Жесты тачпада)
1. Pinch to zoom in and out. Double-tap with two fingers to zoom in on a place.
2. Turn the gestures off in Settings → Keys and gestures → Trackpad gestures (Жесты тачпада) if you do not want them.

## Screen is not supported on this server (The server screen is available on Linux servers)

<!-- id: screen-unsupported; covers: -->
The server screen works only on Linux servers with a desktop. On other servers the page says The server screen is available on Linux servers (The server screen is available on Linux servers).
Где: Server screen → page message
1. Use the Terminals or the Browser mode instead, or connect a Linux server.
