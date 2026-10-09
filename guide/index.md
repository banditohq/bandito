# Bandito guide (index)

Step-by-step reference for the Bandito Mac app, for the current version. The app is the source of truth:
every screen, setting and command here maps to code in `apps/mac/BanditoKit/Sources/BanditoUI`, and
`python3 scripts/check_guide.py` fails when something in the app is not described here.

Conventions used in every entry:

- `Где:` (Where:) is the path to the element, `Menu → Mode → Button`. Button and menu names are the English
  strings from `i18n/en.json`; the Russian strings from `i18n/ru.json` are in brackets.
- `status: planned` means the screen or action is in the design but not working in this build. The entry says
  what is shown instead.
- Keyboard shortcuts are the defaults of the `Bandito` preset. Users can change them, see `keys.md`.

## Files

- [getting-started.md](getting-started.md): first launch, account, the first server, components, the first agent.
- [team.md](team.md): the Team mode: agents, chat, slash commands, approvals, inspector, memory, chapters, changes and rollback.
- [new-agent.md](new-agent.md): creating an agent: runtime, model, effort, fallback, project folder, workplace, memory, approvals.
- [files.md](files.md): the Files mode and the file viewer.
- [terminals.md](terminals.md): the Terminals mode: panes, layouts, collapse, input to all.
- [browser.md](browser.md): the Browser mode on the server.
- [screen.md](screen.md): the Server screen mode: view, take control, quality.
- [server.md](server.md): the Server mode: overview, workplaces, secrets, ports, devices, updates, daemon log.
- [settings.md](settings.md): every Settings section and every setting, with its path.
- [keys.md](keys.md): every command with its default shortcut and how to change it.
- [account.md](account.md): sign-in, devices, sign-out, reset.
- [security.md](security.md): approvals, approval modes, what agents may never do, workplaces, the sandbox.
- [troubleshooting.md](troubleshooting.md): error messages and what to do with them.

## Modes

| Mode (ru) | Shortcut | File |
|---|---|---|
| Team (Команда) | ⌘1 | [team.md](team.md) |
| Files (Файлы) | ⌘2 | [files.md](files.md) |
| Terminals (Терминалы) | ⌘3 | [terminals.md](terminals.md) |
| Browser (Браузер) | ⌘4 | [browser.md](browser.md) |
| Server screen (Экран сервера) | ⌘5 | [screen.md](screen.md) |
| Server (Сервер) | ⌘6 | [server.md](server.md) |
