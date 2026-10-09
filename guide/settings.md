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
The first section. It holds the interface language, the sample data switch, launch at login, and how Bandito updates itself.
Где: Settings (⌘,) → General (Общие)
1. Language (Язык) and Show examples (Показывать примеры) and Launch at login (Запускать при входе в систему) are described below. Check for updates automatically (Проверять обновления автоматически) and Update channel (Канал обновлений) are described at the end of this section.

## Language in General (Language)

<!-- id: set-language-general; covers: setting:AppleLanguages -->
Sets the language of the interface. It applies after you restart Bandito.
Где: Settings (⌘,) → General (Общие) → Language (Язык)
1. Pick a language in the list, or System (Системная) to follow the system language.
2. Quit and open Bandito again: the language changes after the restart (Applies after you restart Bandito).

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
Где: Settings (⌘,) → General (Общие) → Check for updates automatically (Проверять обновления автоматически)
1. Turn the switch off to stop the daily check. Check for Updates… (Проверить обновления…) in the Bandito menu still works.
2. When a new version is found, the update window shows it. Click Install Update (Установить обновление), or pick Remind Me Later (Напоминать позже) or Skip This Version (Пропустить эту версию).

## Update channel (Канал обновлений)

<!-- id: set-update-channel; covers: setting:updates.channel -->
Stable (Стабильный) gets the released versions. Beta (Бета) also gets preview builds, which come earlier and may have rough edges.
Где: Settings (⌘,) → General (Общие) → Update channel (Канал обновлений)
1. Pick Stable (Стабильный) for the released versions only, or Beta (Бета) for the preview builds too.
2. Check for Updates… (Проверить обновления…) uses the channel that is picked now.

## Account and sync (Аккаунт и синхронизация)

<!-- id: set-account; covers: settings:account -->
Shows whether this Mac is signed in and syncs servers, shortcuts and prompts. Without an account everything works on this Mac.
Где: Settings (⌘,) → Account and sync (Аккаунт и синхронизация)
1. Read the state: Account (Аккаунт). Without sign-in, the line says Not signed in. Everything works on this Mac and without an account.
2. Sign in: the Sign in (Войти) button opens the account sheet, the same sign-in as the account step of the introduction (see [account.md](account.md)).

## Servers (Серверы)

<!-- id: set-servers; covers: settings:servers -->
The servers this app connects to. Each keeps its own agents and settings. You can see the state of each and remove one.
Где: Settings (⌘,) → Servers (Серверы)
1. Read the state chip of each server: Online (В сети), Offline (Не в сети), or Connecting (Подключение).
2. To remove a server, click Delete (Удалить) in its row and confirm Delete (Удалить) in Remove {name}?. The app forgets the server and its token. Nothing on the server is deleted.
3. Add server (Добавить сервер) opens the add-server sheet: the server step of the introduction, without its steps (see [getting-started.md](getting-started.md)).

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

## Workplaces (Рабочие места)

<!-- id: set-workplaces; covers: settings:workplaces -->
Workplaces are set up on the Server screen, not here. This section points there.
Где: Settings (⌘,) → Workplaces (Рабочие места) → Open Server → Workplaces (Рабочие места)
1. Click Open Server → Workplaces. The Server mode opens on Workplaces (see [server.md](server.md)).

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

## Appearance and motion (Внешний вид и анимации)

<!-- id: set-appearance; covers: settings:appearance -->
How the app looks and how much it moves.
Где: Settings (⌘,) → Appearance and motion (Внешний вид и анимации)
1. Theme (Тема): the app is dark in this build. There is no theme switch yet.

## Animation level (motion.level)

<!-- id: set-motion; covers: setting:motion.level -->
The amount of motion in the app: Full (Полные), Less (Меньше), or Off (Выключены). Off stops all motion, like Reduce Motion in the system.
Где: Settings (⌘,) → Appearance and motion (Внешний вид и анимации) → Animation (Анимации)
1. Pick Full, Less, or Off. The change applies at once.

## Language (Язык)

<!-- id: set-language; covers: settings:language -->
The same language choice as in General, shown in its own section. It applies after you restart Bandito.
Где: Settings (⌘,) → Language (Язык)
1. Pick a language, or System (Системная). Quit and open Bandito again.

## Updates (Обновления)

<!-- id: set-updates; covers: settings:updates -->
The version of this app and of the daemon on the server. You can check for a new version of the app, and open the server's update page.
Где: Settings (⌘,) → Updates (Обновления)
1. Read App (Приложение) and Daemon on the server (Демон на сервере). Latest release (Последний релиз) shows the newest version, or unknown.
2. Click Check now (Проверить сейчас) to check again.
3. Click Open Server → Updates (Обновления) to update the server's daemon (see [server.md](server.md)).
