# Settings (Настройки)

The Settings window has a list of 13 sections on the left and the section on the right. Open it with ⌘, or from the menu
Bandito → Settings (Настройки). Each entry below gives the path to the setting. Settings are stored on this Mac, except
the approval rules and the server list, which live on the server and in your account.

## Settings window (⌘,)

<!-- id: set-window; covers: command:global.settings -->
Opens the Settings window. It is a separate window, not a sheet over the main window.
Где: Bandito → Settings (Настройки); shortcut ⌘,
1. Press ⌘, to open Settings. Choose a section on the left.
2. Close the window with ⌘W or the window close button.

## General (Общие)

<!-- id: set-general; covers: settings:general -->
The first section. It holds the interface language, the sample data switch, and launch at login. How Bandito updates itself is in Updates (Обновления).
Где: Settings (⌘,) → General (Общие)
1. Language (Язык), Show examples (Показывать примеры) and Launch at login (Запускать при входе в систему) are described below. Check for updates automatically (Проверять обновления автоматически) and Update channel (Канал обновлений) are in Updates (Обновления), see below.

## Language in General (Language)

<!-- id: set-language-general; covers: setting:AppleLanguages -->
Sets the language of the interface. It applies after you restart Bandito.
Где: Settings (⌘,) → General (Общие) → Language (Язык)
1. Pick a language in the list, or System (Системная) to follow the system language.
2. Quit and open Bandito again: the language changes after the restart (Applies after you restart Bandito).
3. The label on the first screen shows the language the interface uses now, written in that language (Русский, English, 日本語). Picking a language there works the same way: it applies after a restart, and the app says so.

## Open links from chat in (Ссылки из чата открывать)

<!-- id: set-chat-links; covers: setting:chatLinks.openTarget, setting:chatLinks.signInInMacBrowser -->
Sets where a web address from a chat opens on a click: in the built-in browser in the workbench panel (the default), or in the browser of the Mac. ⌘-click always opens it the other way. Sign-in pages (Google, Microsoft, Apple, GitHub login, Composio, Auth0, and any login or OAuth page) open in the browser of the Mac when Sign-in links open in the Mac browser (Ссылки входа в сервисы — в браузере Mac) is on, which is the default. ⌘ reverses this for sign-in pages too.
Где: Settings (⌘,) → General (Общие) → Open links from chat in (Ссылки из чата открывать), and Sign-in links open in the Mac browser (Ссылки входа в сервисы — в браузере Mac)
1. Choose Built-in browser (Во встроенном браузере) or Mac browser (В браузере Mac).
2. Keep Sign-in links open in the Mac browser on, so that a login page opens where you are already signed in. Turn it off to open sign-in pages by the rule above.
3. A click on a link in a message follows the choice; ⌘-click takes the other browser, for sign-in pages as well. The first web link you click shows a note with the same explanation, once.

## Show examples (Показывать примеры)

<!-- id: set-show-examples; covers: setting:demo.enabled -->
When the server has no data for a screen yet, the app shows sample agents and limits marked Example (Пример). Real data always wins. The switch is on by default while a server lacks a feature.
Где: Settings (⌘,) → General (Общие) → Show examples (Показывать примеры)
1. Turn the switch off to hide the sample data. Screens that have no real data then show an empty state.
2. Turn it on to see the sample data again.

## Launch at login (Запускать при входе в систему)

<!-- id: set-launch-login; covers: -->
Starts Bandito when you sign in to this Mac. It uses the macOS login items; the setting is not stored by Bandito.
Где: Settings (⌘,) → General (Общие) → Launch at login (Запускать при входе в систему)
1. Turn the switch on. If macOS refuses, the message says Could not change the login item: … (Could not change the login item: {error}).

## Check for updates automatically (Проверять обновления автоматически)

<!-- id: set-auto-update; covers: setting:SUEnableAutomaticChecks -->
Bandito checks for a new version once a day and tells you when one is out. It never installs anything without your OK. The switch is on by default.
Где: Settings (⌘,) → Updates (Обновления) → Check for updates automatically (Проверять обновления автоматически)
1. Turn the switch off to stop the daily check. Check for Updates… (Проверить обновления…) in the Bandito menu still works.
2. When a new version is found, a card appears in the sidebar above your profile (see "Update card in the sidebar" below). Click Update (Обновить) there.

## Update channel (Канал обновлений)

<!-- id: set-update-channel; covers: setting:updates.channel -->
Stable (Стабильный) gets the released versions. Beta (Бета) also gets preview builds, which come earlier and may have rough edges.
Где: Settings (⌘,) → Updates (Обновления) → Update channel (Канал обновлений)
1. Pick Stable (Стабильный) for the released versions only, or Beta (Бета) for the preview builds too.
2. Check for Updates… (Проверить обновления…) uses the channel that is picked now.

## Update card in the sidebar (Плашка обновления)

<!-- id: set-update-card; covers: -->
When a new version of Bandito is out, a card appears in the sidebar above your profile: Version {version} is available (Доступна версия {version}). Update (Обновить) downloads it, installs it and restarts Bandito by itself; no other window opens. Nothing shows when the check at launch finds no new version or has no network.
Где: Sidebar → above your profile → Update (Обновить)
1. Click Update (Обновить). The card shows Downloading the update (Скачиваем обновление) with a bar and the percent, then Preparing the install… (Готовим установку…) and Restarting Bandito… (Перезапускаем Bandito…). Bandito closes and opens again on the new version.
2. Click What's new (Что нового) to read the release notes on GitHub.
3. Click the cross (Напомнить позже) to hide the card. Bandito shows it again at the next check.
4. Check for Updates… (Проверить обновления…) in the Bandito menu, or Check now (Проверить сейчас) in Settings → Updates (Обновления), shows Checking for updates… (Проверяем обновления…) in the same card, then You have the latest version (У вас последняя версия), which goes away after a few seconds.
5. If the update does not work, the card says Could not update (Не получилось обновить) and the reason. Click Try again (Повторить), or the cross to close it.

## Account (Аккаунт)

<!-- id: set-account; covers: settings:account -->
Shows whether this Mac is signed in and syncs servers, shortcuts and prompts. Without an account everything works on this Mac.
Где: Settings (⌘,) → Account (Аккаунт)
1. Read the state: Account (Аккаунт). Without sign-in, the line says Not signed in. Everything works on this Mac and without an account.
2. Sign in: the Sign in (Войти) button opens the account sheet, the same sign-in as the account step of the introduction (see [account.md](account.md)).

## Servers (Серверы)

<!-- id: set-servers; covers: settings:servers -->
The servers this app connects to. Each keeps its own agents and settings. You can see the state of each and remove one.
Где: Settings (⌘,) → Servers (Серверы)
1. Read the state chip of each server: Online (В сети), Offline (Не в сети), or Connecting (Подключение).
2. To remove a server, click Delete (Удалить) in its row and confirm Delete (Удалить) in Remove {name}?. The app forgets the server and its token. Nothing on the server is deleted.
3. Add server (Добавить сервер) opens the add-server sheet: the server step of the introduction, without its steps (see [getting-started.md](getting-started.md)).
4. Drag a server up or down to change the order. The same order is in the server menu at the top of the sidebar.

## Server settings (Настройки сервера)

<!-- id: set-server-settings; covers: settings:servers -->
Click a server in Servers (Серверы) to open its settings. The app keeps the choices in Main (Основное) on this Mac; the server's own settings are saved on the server at once. The server's own settings need a server that is up to date; an older one says so. The same page opens from the Settings link on the Server screen.
Где: Settings (⌘,) → Servers (Серверы) → a server; or Server → Настройки сервера
1. Main (Основное): Name (Название) is how the app shows the server; Enter or leaving the field saves it. Icon (Значок) and Color (Цвет) mark the server in the server menu and the sidebar. Main server (Основной сервер) opens at launch; only one server can be it, and choosing another one moves it. Notifications from this server (Уведомления с этого сервера) are All (Все), Waiting for you (Ждёт вас), or Off (Выключены); the global notification settings still apply.
2. Connection (Подключение): for an ssh server, Address (Адрес), User (Пользователь), SSH port (Порт SSH) and SSH key (Ключ SSH) say how the app reaches it; empty user and port mean ssh's own. Choose… (Выбрать…) picks a key file, starting in ~/.ssh. A WebSocket server has its Address (Адрес) instead. A change is saved when you press Enter or leave the field, and the server reconnects. Check the connection (Проверить связь) says how quickly the server answers, or why it does not. Reconnect (Переподключить) opens the link again. Switch off for now (Отключить на время) keeps the app from connecting until it is turned off; the server is grey in the server menu. Remove from the app (Удалить из приложения) forgets the server and its token; nothing on the server changes.
3. Agents by default (Агенты по умолчанию): Agents folder (Папка агентов) is where the new-agent sheet starts for this server (Choose… (Выбрать…) picks it). Permission mode for new agents (Режим разрешений новых агентов) is the mode an agent gets when its creation does not set one. Agents working at once (Агентов работает одновременно) limits how many agents run a turn; the others wait in their queue. No limit (Без ограничения) is 0.
4. Maintenance (Обслуживание): Server updates (Обновления сервера) is Off (Выкл), Notify (Уведомлять), or At night (Ночью), when a newer version is installed while no agent works. Screen stops after (Экран останавливается через) sets the idle time of a server screen. How often a copy is made and Copies kept (Хранить копий) set the database copies; Make copy (Сделать копию) makes one now. Open logs (Открыть логи) opens the Server journal. Copy report (Скопировать отчёт) copies versions and the system for support, with no addresses, tokens or paths.
5. About the server (О сервере): the daemon version, the system, the processor, the memory, the disk and the uptime.

## Approvals (Одобрения)

<!-- id: set-approvals; covers: settings:approvals -->
The rules for what agents may do without asking, and the checks that always run. The rules are stored on the server and apply there. The built-in checks cannot be switched off. See [security.md](security.md).
Где: Settings (⌘,) → Approvals (Одобрения)
1. The rules table shows Action (Действие), Behavior (Поведение) and For (Для кого). If the server is older, the section shows Update the server (Обновите сервер) instead of the table.
2. To add a rule, click New rule (Новое правило). Type the pattern in When the agent wants to run (Когда агент хочет выполнить), for example terraform plan*. Pick Then (То): Allow (Разрешить), Ask (Спрашивать) or Deny (Отклонить). Pick For (Для кого): All agents (Все агенты) or one agent. Click Add (Добавить). The * means anything.
3. If two rules match, the rule for one agent wins over All agents, then the newer rule wins.
4. To delete a rule, click its delete button (Delete rule {pattern}).
5. Built-in checks are always on: writes outside the project folder, Pay and Buy, Send in forms, Delete on sites, sign-in with a password. A rule for one agent can override them.
6. Touch ID for dangerous steps and auto-deny after 30 minutes are not offered in this build, so no switch for them is shown. Approvals wait up to 24 hours and then are denied.
## Approvals: Touch ID for dangerous steps (planned)

<!-- id: set-approvals-touchid; covers: ; status: planned -->
Touch ID (or Face ID) for pushes to main, deploys and deletions is planned. It is not in this build, and Settings → Approvals shows no switch for it.
Где: Settings (⌘,) → Approvals (Одобрения)
1. Nothing to set yet. Approve dangerous steps in the approval card.
## Approvals: auto-deny after 30 minutes (planned)

<!-- id: set-approvals-autodeny; covers: ; status: planned -->
An automatic denial after 30 minutes without an answer is planned. It is not in this build: a request waits up to 24 hours, and Settings → Approvals shows no switch for it.
Где: Settings (⌘,) → Approvals (Одобрения)
1. Answer approval requests in time.

## Subscriptions and limits (Подписки и лимиты)

<!-- id: set-usage; covers: settings:usage -->
Shows the subscription limits of each runtime: the 5-hour and weekly windows, and when they reset. It also shows the API budget for agents that use an API key.
Где: Settings (⌘,) → Subscriptions and limits (Подписки и лимиты); the same list is in the Usage popover (⌥⌘U) in the sidebar
1. Read the bars: each shows what is left in its window (5 hours (5 hours), Week (Неделя)). The reset time is shown under the bar.
2. Click Refresh (Обновить) to get the latest limits. If none were received yet, the section says No limits received yet.
3. The fallback note explains that if a limit runs out, the agent switches to its backup subscription and returns after the reset.

## Terminal and files (Терминал и файлы)

<!-- id: set-terminal-files; covers: settings:terminalFiles -->
How the terminals and the file browser look and start.
Где: Settings (⌘,) → Terminal and files (Терминал и файлы)
1. Text size (Размер текста): the size of the text in the terminals, in points. It applies to all terminals, and ⌘+ and ⌘− change it too (see the entry below).
2. Show hidden files (Показывать скрытые файлы): when a folder opens, hidden files are shown. ⌘⇧. toggles it in the file browser.

## Text size in terminals (terminal.fontSize)

<!-- id: set-font-size; covers: setting:terminal.fontSize -->
The one text size of all terminals, stored on this Mac. It is set by the stepper here and by ⌘+, ⌘− and ⌘0 in a terminal.
Где: Settings (⌘,) → Terminal and files (Терминал и файлы) → Text size (Размер текста)
1. Click the stepper to change the size. The value in pt is shown next to it.

## Show hidden files in folders (files.showHiddenByDefault)

<!-- id: set-show-hidden; covers: setting:files.showHiddenByDefault -->
Whether hidden files (names that start with a dot) are shown when a folder opens in the Files mode.
Где: Settings (⌘,) → Terminal and files (Терминал и файлы) → Show hidden files (Показывать скрытые файлы)
1. Turn the switch on to show hidden files by default. The toggle ⌘⇧. still works in the Files mode.

## Browser and screen (Браузер и экран)

<!-- id: set-browser-screen; covers: settings:browserScreen -->
How the server's browser and screen look on this Mac.
Где: Settings (⌘,) → Browser and screen (Браузер и экран)
1. Picture quality (Качество картинки) and Shared clipboard (Общий буфер обмена) are described below.

## Picture quality of the screen (screen.quality)

<!-- id: set-screen-quality; covers: setting:screen.quality -->
The picture quality of the server screen: Auto (Авто), Faster (Быстрее) for less data, or Sharper (Чётче) for more detail. Changing it reconnects the screen.
Где: Settings (⌘,) → Browser and screen (Браузер и экран) → Picture quality (Качество картинки)
1. Pick Auto, Faster, or Sharper. The same choice is in the Server screen toolbar (see [screen.md](screen.md)).

## Shared clipboard (screen.sharedClipboard)

<!-- id: set-clipboard; covers: setting:screen.sharedClipboard -->
Shares the clipboard between this Mac and the server's screen. It is on by default.
Где: Settings (⌘,) → Browser and screen (Браузер и экран) → Shared clipboard (Общий буфер обмена)
1. Turn the switch off to stop sharing the clipboard. Copy here and paste there works only while it is on.

## Keys and gestures (Клавиши и жесты)

<!-- id: set-keys-gestures; covers: settings:keysGestures -->
Every shortcut by context, with a search field, presets, export and import. The Trackpad gestures tab switches the gestures on and off.
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Keys (Клавиши) or Trackpad gestures (Жесты тачпада)
1. Use the search field Find an action or press a shortcut (Найти действие или нажмите сочетание) to find a command.
2. Pick a preset in the list: Bandito (Bandito), Like VS Code (Как в VS Code), Like iTerm (Как в iTerm) or Like Slack (Как в Slack).
3. To change a shortcut, click it and press the new keys. If another command uses it, the row shows taken by: {name}; click Replace (Заменить) to swap.
4. The counter Changed by you: N shows how many shortcuts differ from the defaults. Reset all (Сбросить всё) restores the defaults.
5. Export (Экспорт) saves the shortcuts to a file. Import (Импорт) loads them. A file that is not a keymap is refused: This file is not a keymap Bandito can read.

## Shortcut storage (keymap.v1)

<!-- id: set-keymap-storage; covers: setting:keymap.v1 -->
The changed shortcuts are stored on this Mac under the key keymap.v1, as JSON. Only the changes are stored; the rest are the defaults.
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Keys (Клавиши)
1. Nothing to set by hand. Use Export to keep a copy of your shortcuts.

## Trackpad gestures (Жесты тачпада) and swipe sensitivity (gestures.v1)

<!-- id: set-gestures; covers: setting:gestures.v1 -->
Six gestures can be switched on or off one by one, and one slider sets how far a swipe goes. The choices are stored on this Mac under gestures.v1.
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Trackpad gestures (Жесты тачпада)
1. Switch off a gesture: Swipe with two fingers — back and forward (Two-finger swipe — back and forward), Swipe on an agent — actions (Swipe on an agent — actions), Pinch — zoom (Pinch — zoom), Pinch out — full screen (Pinch out — full screen), Force click — preview (Force click — preview), Two-finger double tap.
2. Move the slider Swipe sensitivity (Чувствительность свайпов) between softer (softer) and sharper (sharper).

## Notifications (Уведомления)

<!-- id: set-notifications; covers: settings:notifications -->
Bandito tells you when an agent needs you. Choose what is worth a notification. The system permission is needed first.
Где: Settings (⌘,) → Notifications (Уведомления)
1. System notifications (Системные уведомления): the status reads Allowed (Разрешено), Off in System Settings (Выключено в Системных настройках), or Not asked yet (Ещё не спрашивали). Click Allow (Разрешить) to ask macOS for permission. If it is off, turn it on in System Settings.
2. Choose the events below.

## Notify: waiting for you (notify.needsYou)

<!-- id: set-notify-needs-you; covers: setting:notify.needsYou -->
A notification when an agent waits for you: an approval or a question.
Где: Settings (⌘,) → Notifications (Уведомления) → Waiting for you (Ждут вас)
1. Turn the switch on or off. It is on by default.

## Notify: done (notify.finished)

<!-- id: set-notify-finished; covers: setting:notify.finished -->
A notification when a task is complete.
Где: Settings (⌘,) → Notifications (Уведомления) → Done (Готово)
1. Turn the switch on or off. It is on by default.

## Notify: error (notify.error)

<!-- id: set-notify-error; covers: setting:notify.error -->
A notification when an agent stops because of a failure.
Где: Settings (⌘,) → Notifications (Уведомления) → Error (Ошибка)
1. Turn the switch on or off. It is on by default.

## Telegram

<!-- id: set-telegram; covers: settings:telegram -->
Approvals and agent replies can go to a Telegram chat, and you can write to agents from there. You bring the bot: create it in @BotFather and paste its token here. The token is stored on the server only, and the app never shows it again. The section appears when the server is version 0.1.8 or later.
Где: Settings (⌘,) → Telegram
1. Create a bot in @BotFather (send /newbot), paste its token into the Bot token (Токен бота) field and press Connect (Подключить). Telegram checks the token first; a refused token shows a message under the field.
2. Press Link Telegram (Привязать Telegram). Scan the QR code with your phone, or press Open in Telegram (Открыть в Telegram), then press Start in the chat with the bot. The code is valid for ten minutes; when it runs out, press Get a new code (Получить новый код). The window closes by itself when the chat is linked.
3. For each chat, choose Approvals (Одобрения) to be asked there when an agent needs approval, and Agent replies (Ответы агентов): All (Все), From Telegram (only the turns you started in Telegram) or None (Нет). Unlink (Отвязать) removes the chat.
4. Disconnect bot (Отключить бота) deletes the token and unlinks every chat after you confirm. The bot line says Working (Работает) or Stopped (Остановлен); a problem with the bot is shown in words under it.

## Sounds (Звуки)

<!-- id: set-sounds; covers: settings:sounds -->
Short sounds for clicks, typing, switching tabs, sending a message, and agent events. Off by default.
Где: Settings (⌘,) → Sounds (Звуки)
1. Turn on Sounds (Звуки) to hear them.
2. Each event (click, typing, tab, send, done, waiting for you, error) has its own switch.

## Sounds on (sound.enabled)

<!-- id: set-sound-enabled; covers: setting:sound.enabled -->
The main switch of all app sounds. Off by default.
Где: Settings (⌘,) → Sounds (Звуки) → Sounds (Звуки)
1. Turn it on; the other controls become active.

## Sound pack (sound.kit)

<!-- id: set-sound-kit; covers: setting:sound.kit -->
Seven packs made by the app itself: Soft (Мягкий), Mechanical (Механика), Glass (Стекло), Crystal (Кристалл), Marimba (Маримба), Retro (Ретро), Arcade (Аркада).
Где: Settings (⌘,) → Sounds (Звуки) → Pack (Набор)
1. Pick a pack; ▶ plays a sample: a message sound, then a success sound.

## Volume (sound.volume)

<!-- id: set-sound-volume; covers: setting:sound.volume -->
How loud the app sounds are, separate from the Mac volume.
Где: Settings (⌘,) → Sounds (Звуки) → Volume (Громкость)
1. Drag the slider.

## Sounds when the window is in the background (sound.background)

<!-- id: set-sound-background; covers: setting:sound.background -->
When no Bandito window is on screen, only "agent finished" and "agent waits for you" can play, and only with this switch on.
Где: Settings (⌘,) → Sounds (Звуки) → Also when the window is in the background (И когда окно в фоне)
1. Turn it on to hear agents while you work in other apps.

## Appearance (Внешний вид)

<!-- id: set-appearance; covers: settings:appearance -->
How the app looks and how much it moves.
Где: Settings (⌘,) → Appearance (Внешний вид)
1. Theme (Тема): the app is dark in this build. There is no theme switch yet.

## Animation level (motion.level)

<!-- id: set-motion; covers: setting:motion.level -->
The amount of motion in the app: Full (Полные), Less (Меньше), or Off (Выключены). Off stops all motion, like Reduce Motion in the system.
Где: Settings (⌘,) → Appearance (Внешний вид) → Animation (Анимации)
1. Pick Full, Less, or Off. The change applies at once.

## Updates (Обновления)

<!-- id: set-updates; covers: settings:updates -->
The version of this app and of the daemon on the server. You can check for a new version of the app, and open the server's update page.
Где: Settings (⌘,) → Updates (Обновления)
1. Read App (Приложение) and Daemon on the server (Демон на сервере). Latest release (Последний релиз) shows the newest version, or unknown.
2. The first row is the app's own update: Check now (Проверить сейчас) looks for a new version, and the row then shows the same words as the sidebar card, with Update (Обновить) when a version is on offer. The Check now button at the bottom of the page does the same and also re-reads Latest release.
3. Click Open Server → Updates (Обновления) to update the server's daemon (see [server.md](server.md)).

## Privacy (Конфиденциальность)

<!-- id: set-privacy; covers: settings:privacy -->
What Bandito sends to its team: anonymous counts of the features you use, a daily check-in (version, system, number of servers and agents as ranges), and crash reports if you allow them. Nothing about your messages, code, files, server addresses or keys is sent. Anonymous statistics are on by default; turning them off stops sending and erases the counts. With them off, Bandito still asks the team for announcements every 6 hours, sending only the interface language and the app and system versions (no install id). "Delete my data" removes what this Mac sent from our servers. The first-run notice and the crash question each appear once; the strip at the top of the window shows a message from the team once.
Где: Settings (⌘,) → Privacy (Конфиденциальность)
1. Turn Anonymous statistics (Анонимная статистика) off to stop sending counts.
2. Turn Crash reports (Отчёты о сбоях) on to send the error type and function names after a crash.
3. Delete my data (Удалить мои данные) asks for confirmation, then deletes what was sent. The privacy policy link opens bandito.dev/privacy.
