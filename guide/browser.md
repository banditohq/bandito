# Browser (Браузер)

A Chrome browser that runs on the server. Your sign-ins are kept there, and agents see the same tabs you see.
You can watch an agent browse, take control of the page, or give it back. Open the mode with ⌘4.

## Browser mode

<!-- id: browser-mode; covers: mode:browser -->
The window has a toolbar with the address bar, the tabs, and the page. A banner shows when an agent drives the browser.
Где: Mode bar → Browser (Браузер), or Menu View → Browser (Браузер)
1. Press ⌘4 or click Browser (Браузер) in the mode bar.
2. If the browser is not running, click Start browser (Запустить браузер).
3. The first time, Chrome must be installed on the server. See the next section.

## Install Chrome on the server (Install)

<!-- id: browser-install-chrome; covers: -->
The browser needs Google Chrome on the server. Bandito can install it. The browser keeps its sign-ins across the install.
Где: Browser → Chrome is needed for the browser (Для браузера нужен Chrome) → Install (Установить)
1. Click Install (Установить). The status says Installing… this can take a few minutes.
2. When the install ends, the browser opens. If it fails, the message says The install did not finish. See the server log (The install did not finish. See the server log.). Read the log in Server → Daemon log (see [server.md](server.md)).
3. If the server is older, the browser shows The browser appears after the server is updated (The browser appears after the server is updated). Click Open Server (Открыть «Сервер») and update the server.

## Address bar and tabs (Address, Tabs)

<!-- id: browser-address; covers: -->
Type an address to open a page in the current tab. Tabs lists the tabs open on the server, and Agents opened shows the tabs that agents opened.
Где: Browser → toolbar → Address (Адрес); shortcut ⌘L (Address bar)
1. Click the address bar, or press ⌘L (Address bar). Type a web address and press ↵.
2. Use Back (Назад) and Forward (Вперёд) to move through the history of the tab.
3. Press ⌘R (Reload) or click Reload (Обновить) to load the page again.
4. Press ⌘T (New tab) to open a new tab.

## Open a preview of a server port (Preview, Open)

<!-- id: browser-preview; covers: -->
When an agent starts a web server on the server (for example on a port), you can open it in the browser. The port is also listed in the Server mode under Ports (see [server.md](server.md)).
Где: Browser → Preview (Превью) → Open (Открыть); or Quick open (⌘K) → Open :{port} — {process} (Open :{port} — {process})
1. Type the port in the palette, or click Open (Открыть) next to the port.
2. If the page does not load, the message says The preview did not load (Превью не загрузилось).

## Take control of the browser (Take control)

<!-- id: browser-take-control; covers: command:browser.takeControl -->
When an agent drives the browser, you can take the control to click and type yourself, then give it back.
Где: Browser → banner → Take control (Взять управление); shortcut ⌘⇧C (Take / give back control)
1. Press ⌘⇧C, or click Take control (Взять управление) in the banner. The banner says You (Вы) as the one in control.
2. Click or type in the page. To ask the agent to continue, click Give to agent (Отдать агенту) in the banner.
3. Click Pause (Приостановить) to pause the agent in the browser. The banner says Paused (На паузе) and the agent waits.
4. When an agent asks for the control, the banner says Take control to click here? (Take control to click here?).

## Risky steps in the browser (approvals)

<!-- id: browser-risky; covers: -->
Some clicks in a browser are asked about before they happen: Pay and Buy, Send in forms, Delete on sites, and sign-in with a password. The approval card appears in the agent's thread; see [security.md](security.md).
Где: Team → agent thread → approval card (Needs you)
1. Read the step in the card. Click Approve (Разрешить) or Deny (Отклонить).

## Open a link on this Mac (Open on Mac)

<!-- id: browser-open-mac; covers: -->
When the page has a link that must open in a Mac browser, a button appears in the toolbar. It opens the link in the Mac's default browser.
Где: Browser → toolbar → Open on Mac (Открыть на Mac)
1. Click Open on Mac (Открыть на Mac) to open the link in the Mac's default browser.

## Trackpad in the browser (Two-finger double tap)

<!-- id: browser-gestures; covers: -->
Two-finger swipe moves back and forward through the pages, and an arrow at the edge shows where it goes (⌘[ and ⌘] do the same). A sideways swipe is not scrolled into the page; scroll sideways with Shift and the wheel. The wheel and the trackpad scroll the page up and down. A two-finger double tap zooms in on a place on the page.
Где: Browser → two-finger swipe / two-finger double tap; Settings → Keys and gestures (Клавиши и жесты) → Trackpad gestures (Жесты тачпада)
1. Swipe with two fingers: right to go back, left to go forward.
2. Double-tap with two fingers to zoom in. Do it again to zoom out.
3. Switch the gestures off in Settings → Keys and gestures → Trackpad gestures (Жесты тачпада) if you do not want them.

## Close a tab (⌘W)

<!-- id: browser-close-tab; covers: -->
Closes the shown tab. A tab that hangs and does not answer is closed anyway after 3 seconds, and the next tab opens in its place.
Где: Browser → ⌘W, or the × on a tab
1. Press ⌘W while the Browser mode is shown.
2. If the tab does not answer, wait a moment: the server closes it by force.
Хоткей: ⌘W
