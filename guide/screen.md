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
2. Under Screens of workplaces (Экраны рабочих мест), see the screens that agents use. Click one to open it.

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
