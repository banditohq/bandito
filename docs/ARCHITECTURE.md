# Bandito architecture (MVP)

Status: working design, October 2026. This file is the source of truth for the MVP; change it in the same PR as the code.

## Pieces

```
 Mac app (SwiftUI)                 your server
 ┌──────────────┐   transport   ┌──────────────────────────────────────────┐
 │ crew, threads│◀────────────▶│ bandito daemon (Rust, one binary)          │
 │ approvals    │  JSON-RPC 2.0 │  ├─ rpc: unix socket + HTTP/WebSocket     │
 │ schedules    │  over WS      │  ├─ store: SQLite (agents, events, ...)   │
 └──────────────┘               │  ├─ policy: what needs a human            │
                                │  ├─ scheduler: cron → prompts             │
                                │  ├─ crew MCP: agents talk to each other   │
                                │  └─ runtimes ─┬─ claude  (stream-json)    │
                                │               ├─ codex   (app-server)     │
                                │               ├─ grok    (ACP)            │
                                │               └─ api     (own loop)       │
                                └──────────────────────────────────────────┘
```

- The daemon runs as the user who owns the CLI logins (`~/.claude`, `~/.codex`, `~/.grok`), never as root.
- One binary: `bandito daemon` (foreground), `bandito pair`, `bandito info`, `bandito status`, `bandito mcp [--token-file <path>]` (crew MCP over stdio, proxies to the daemon's `agent.sock` with the agent's session token), `bandito service install|uninstall|status` (see [Install and service](#install-and-service)), `bandito update` (see [Self-update](#self-update)).

## Runtimes

Subscription mode drives the official, unmodified CLIs through their own structured stdio protocols. No screen scraping. One child process per agent session.

| Runtime | Command | Protocol | Approvals |
|---|---|---|---|
| Claude Code | `claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio --permission-mode default` | NDJSON; host answers `control_request{subtype:"can_use_tool"}` with `control_response{behavior:"allow"\|"deny"}` | per tool call |
| Codex | `codex app-server --stdio` | JSON-RPC 2.0: `initialize`, `thread/start`, `turn/start`, notifications `item/*`, `turn/completed` | server requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` → `{decision:"accept"\|"decline"\|...}` |
| Grok | `grok agent --no-leader stdio` | ACP (JSON-RPC 2.0): `initialize`, `session/new`, `session/prompt`, notifications `session/update` | `session/request_permission` → `{outcome:{outcome:"selected",optionId}}` |
| API keys | built in | Anthropic Messages / OpenAI Responses / xAI, own tool loop (bash, read, write, edit) | same policy engine |

Recorded protocol transcripts live in `daemon/tests/fixtures/`. Adapter tests run against fake CLIs that replay them, so CI needs no logins.

Every adapter turns its protocol into the same internal events (below). Resuming after a daemon restart uses each CLI's own session id (`--resume`, `thread/resume`, `session/load`), stored on the agent.

Useful extras we surface: Claude's `rate_limit_event` and Codex `account/rateLimits/updated` → subscription usage in the app; `runtimes.status` reports installed / version / logged in for each CLI. `logged_in` is `true` or `false` from `claude auth status` (Claude) and `codex login status` (Codex: exit 0 is logged in, exit 1 with "Not logged in" is logged out). It is `null` when the CLI does not say, fails, or takes more than 5 s, and Grok always reports `null`. The answer is cached per runtime for 60 s, and concurrent requests share one probe. The probe reads no account details: the email and organisation are not kept. Without `.credentials.json` (macOS keeps the Claude login in the Keychain), Claude's plan for usage comes from `claude auth status` too.

### Runtime models

`runtimes.models{runtime?: "claude"|"codex"|"grok", refresh?: bool}` returns the models each agent CLI offers, read from the CLI itself. No model request is sent. Result: `[{runtime, models: [{id, name, description, is_default, efforts}], error, fetched_at}]`, one entry per runtime asked (all three without `runtime`); `runtime: "api"` is `-32602`. `error` is `null`, `"not_installed"` (the CLI is not on the daemon's `PATH`), or a short reason. `id` is the name the CLI takes as its model. `efforts` lists the reasoning levels the model accepts (empty when none). Hidden models are not listed. At most one model has `is_default: true`.

- Claude: `claude -p --setting-sources "" --input-format stream-json --output-format stream-json --verbose` gets a `control_request` `initialize` on stdin; the models are in its `control_response`. The user's settings and hooks are not loaded, and no session is saved (`--no-session-persistence`).
- Codex: `codex app-server --stdio`, `initialize`, then `model/list` page by page (at most 5 pages). Works without a Codex login.
- Grok: `~/.grok/models_cache.json` when it is there, readable, and lists a visible model (the default is `default_model` of `~/.grok/settings_cache.json`; without it, or when that model is not listed, the newest visible model by its version numbers, `grok-4.10` over `grok-4.9`). Otherwise `grok agent --no-leader stdio` over ACP: `session/new` gives the models and `currentModelId`.

Each CLI runs in its own process in `<data dir>/models-probe`, is given 20 s, and is killed when its answer is in, on error, or on timeout. A good list is kept in memory for 15 minutes per runtime, a failed one for 30 seconds; `refresh: true` asks again at once. Concurrent requests for one runtime share one listing. A missing CLI is answered at once and not stored. Code: `daemon/src/runtime/models.rs`. Feature string: `"runtime_models"`.

## Events

Everything an agent does becomes a row in `events` (append-only, global `seq`). Clients subscribe with `events.subscribe{after}` (live events, backfilled from `after`) and load a thread with `events.page{agent_id, before, limit}` (newest page first, each page oldest to newest). Global `seq` is contiguous on one connection, so a client that sees a jump re-subscribes from its last seq; a laptop that slept for a night catches up exactly.

| kind | payload |
|---|---|
| `turn.started` | `{turn_id, source: "user"\|"schedule"\|"crew"}` |
| `message.user` | `{text, source, from_agent?, command?, reply_to?, attachments?}` (`text` is what the person typed; `command` names a slash command, see [Commands](#commands); `reply_to` is the seq of the message it answers and `attachments` the files it carries, see [Replies and attachments](#replies-and-attachments)) |
| `message.assistant` | `{text}` (final text of a message) |
| `message.delta` | `{text}` streaming chunk, **not persisted**, broadcast only |
| `tool.call` | `{call_id, tool, title, input}` |
| `tool.result` | `{call_id, ok, output}` (output truncated to 16 KB) |
| `approval.requested` | `{approval_id, call_id, tool, title, command?, diff?, reason}` |
| `approval.resolved` | `{approval_id, decision: "allow"\|"deny", by: "user"\|"policy", remember}` |
| `approval.withdrawn` | `{approval_id}`: the CLI took the request back (`control_cancel_request`); nobody decided it, so the approval is closed with status `withdrawn` and no decision |
| `turn.completed` | `{turn_id, status: "ok"\|"error"\|"interrupted", usage?, cost_usd?}` |
| `agent.status` | `{status: "idle"\|"working"\|"needs_you"\|"error"\|"offline", detail?}` |
| `usage.limits` | `{runtime, windows:[{name, utilization, resets_at}]}` |
| `runtime.switched` | `{from, to, until?}`: the agent moved to another runtime (see [Fallback subscription](#fallback-subscription)); `until` is when the limit resets (Unix seconds), if known |
| `agent_changed` | `{action: "created"\|"updated"\|"deleted"}`: an agent record was created, changed or deleted, by any client or path (RPC `agents.create`/`update`/`delete`, pause, runtime switch). Clients re-read `agents.list` on `created`/`updated`, and on an event from an agent they do not know; `deleted` removes the agent locally. No event for bookkeeping fields (context size, chapter, session) |
| `form_requested` | `{form_id, title, intro?, kind: "question"\|"confirm", fields, submit_label?, reject_label?}`: the agent asked the person a form (see [Forms](#forms)) |
| `form_answered` | `{form_id, action: "submit"\|"reject"\|"expired", values?, comment?}`: the form ended |
| `reaction` | `{seq, emoji?, by: "user"\|"agent"}`: a reaction on the message with that seq; no `emoji` means it was taken off (see [Reactions](#reactions)) |
| `error` | `{message}` |

Protocol rule for these: new fields are optional, so old clients keep working; new things get a new `kind`, which old clients ignore.

## Forms

An agent asks the person for several answers at once, or for a confirmation before something leaves the server, with the MCP tool `ask_form` instead of questions in text. The tool blocks until the person answers, for at most 24 hours (`APPROVAL_TTL_MS`, the same time as an approval).

The spec: `{title, intro?, kind: "question"|"confirm", fields: [...], submit_label?, reject_label?}`, with up to 20 fields. A field is `{id, label, type, options?, required?, default?, placeholder?, help?}`. `type` is one of `text`, `textarea`, `email` (must contain `@`), `number`, `choice`, `multichoice`, `boolean`, `date` (`YYYY-MM-DD`). `choice` and `multichoice` need 1 to 20 `options`. An `id` is 1 to 64 letters, digits, `_` or `-`, unique in the form. `kind: "confirm"` marks a confirmation before an action outside (a letter, a post, a payment, a deletion): the fields are shown as an editable summary, with Confirm and Reject buttons. A bad spec is a tool error with the reason, and nothing is stored.

Flow: the form is stored (`forms`: `id, agent_id, spec, status, answer, created_at, answered_at`; status `pending`, `submitted`, `rejected` or `expired`), the event `form_requested` goes into the thread, and the agent's status is `needs_you` while the form is open. The answer comes from `forms.answer`: values are checked against the spec (required fields, types, options; an omitted field takes its `default`, an unknown field is refused). The first answer stands: a second one is `already_answered`. The tool returns `{"action": "submit", "values": {...}}`, `{"action": "reject", "comment"?}` or `{"action": "expired"}`, and the event `form_answered` follows.

A form expires when nobody answers in 24 hours, when the turn is cancelled (`agents.interrupt`), when the agent is paused or deleted, when the agent's connection closes while the form waits, and after a daemon restart (a form left open cannot be answered any more). An answer to a form whose call is already gone is refused with `expired`; the form is closed as expired. Expiry is `expired` in the store and in the thread.

`forms.list{agent_id?, status?}` lists forms, newest first. `daemon.info.features` lists `"forms"`, `"reactions"` and `"attachments"` when the daemon has them. Only the owner's CLI and the apps may answer or list forms; an agent may only ask (`forms.agent.ask`).

## Reactions

A person puts one emoji on a message of the agent (`messages.react{agent_id, seq, emoji}`); a new one replaces it, and `emoji: null` takes it off. An agent puts one on a message with the tool `react{seq?, emoji}` (`messages.agent.react`), by default on the person's last message. The event `reaction{seq, emoji?, by}` goes into the thread. Reactions are stored in `reactions(agent_id, seq, by, emoji, at)`, one per message and `by`.

An emoji is one grapheme cluster of at most 16 bytes, with no spaces (a joined family is 18 bytes, so it is refused). A reaction is a message of the thread: `seq` must be a `message.user` or `message.assistant` of that agent.

A reaction by the person on a message of the agent does not start a turn. The reactions made since the last turn that a person started go into the next prompt, as the first line: `(Реакции с прошлого раза: 👍 на «первые 80 символов сообщения…»)`. The window runs from the moment the last human turn read its reactions (recorded as `reactions_until` on its `turn.started`) to the moment this turn reads them. A reaction made after that moment goes into the next prompt, so each reaction is said once.

## Replies and attachments

`agents.send{agent_id, text, reply_to?, attachments?}`. `reply_to` is the seq of a message in the same thread. The prompt then starts with `В ответ на: > <first 300 characters of that message>` and a blank line, and the thread shows the reply in the event's `reply_to`.

Files come first, from `attachments.upload{agent_id, name, data_base64}`. A file is at most 20 MB after decoding. Its name has no `/`, `\`, `..` or control characters, does not start with a dot, and is at most 200 bytes. It is saved in `<agent folder>/.bandito/attachments/<YYYY-MM-DD>/`, or in `<agent home>/files/attachments/<YYYY-MM-DD>/` when the agent has no folder or the folder would be Bandito's own data folder. A name taken on that day becomes `name (2).ext`, `name (3).ext`. The reply is `{path, name, size, mime}` (`mime` from the extension). `agents.send` accepts `attachments: [path]` only for files in those folders of that agent (at most 20 per message). The event `message.user` carries them as `attachments: [{path, name, size, mime}]`, and the prompt lists them after the text: `Вложения:` and one `- <path> (<mime>, <size> байт)` line each. Nothing is written through a link: if `.bandito`, `attachments` or the day folder is a symbolic link, the upload is refused. `agents.send` takes a path only when its real location (links followed) is a file inside one of those folders, and the message carries that real path. The agent reads them by path; the agent's own folder is readable under the approval policy.

## Approvals (policy)

Per agent `approval_mode`:

- `risky` (default): the daemon auto-allows routine tool calls and escalates risky ones to the human.
- `always`: every tool call that the CLI asks about goes to the human.
- `never`: auto-allow everything (for sandboxes).

**Protected: always denied.** Bandito's own files and controls are off limits to agents, in every mode, and no rule can allow them. A call is refused with `Bandito's own files and controls are off limits to agents` when a path it reaches is known to be one of them:

- the data folder (`$BANDITO_HOME`, else `~/.bandito`), reached by a path the command uses (an argument, a redirect target, the program, a file the tool edits or reads), once `~`, `~user` (looked up in the system's account database), `$HOME`, `${HOME}`, `$BANDITO_HOME`, variables set earlier on the same line, `cd`, `pushd` and `popd` are followed. a one-character class names that character (`~/[.]bandito` is the data folder), so it counts; a wildcard that may match the data folder (`~/.ban*/bandito.*`, `~/.*`) is a question (see the next paragraphs), not a refusal, and only a literal path into the data folder is refused (`~/.bandito/*`); the data folder's name counts as a whole path component (`~/.bandito-backup` is another folder), and case differences count (APFS and most Linux setups are case-insensitive);
- a folder that contains the data folder, when the command reaches everything under it: removal, copying, moving or archiving (`rm -r ~`, `cp -r ~ /tmp`, `tar czf h.tgz ~`, `rsync … ~`), a recursive search (`grep -r x ~`, `rg`, `ag`, `ack`, `du`, `tree`, `ls -R`, `find` deeper than depth 1, `git grep` from such a folder), or `ditto`;
- the daemon's own binary, or a command named `bandito`;
- a command that stops, restarts, disables or kills Bandito: `kill` of the daemon's pid or of anything named `bandito`, `pkill`/`killall bandito`, `systemctl … stop|restart|disable bandito*`, `launchctl … bandito`;
- the daemon's service files: `~/.config/systemd/user/bandito*`, `/etc/systemd/system/bandito*`, `~/Library/LaunchAgents/dev.bandito*`;
- the data folder spelled out in the raw command line (`~/.bandito`, `$HOME/.bandito`, `${HOME}/.bandito`, the absolute path), so a `python -c` that names it is refused too.

The Claude runtime also starts with `--settings` carrying `permissions.deny` for `Read`, `Edit` and `Write` under the data folder, so the file tools refuse it without asking. It adds the denials of the agent's [capabilities](#capabilities): `Bash` without `terminal`, and `Edit`, `Write`, `MultiEdit` and `NotebookEdit` without `files`.

It also carries `permissions.ask` for `Bash`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `WebFetch` and `Read`. Claude Code checks deny, then ask, then allow, whatever file a rule came from. So an `allow` in `~/.claude/settings.json`, `.claude/settings.json` or `.claude/settings.local.json` (a user's own, or one in a cloned repository) does not run these tools without the policy: the call goes to `can_use_tool`, and the policy decides as below. The CLI is started with `--permission-mode default` (once), so a `defaultMode` in those files does not win. Grep and Glob are asked about too: Grep reads file contents, Glob lists names under a folder. The policy checks both for credential folders and for Bandito's folder. A search whose folder is inside the data folder is refused in every mode. A search whose folder holds the data folder (its root is above it) is asked about in risky and always modes, and allowed in never mode. Only the folder the search covers is checked (`path`, and a Glob pattern's folder): the pattern and the title are text to find, so `Grep` for `~/.bandito` is not a read of it. LS only lists names and is not asked about.

**Known limit, not fixed in this version.** Tools outside that list (`mcp__*` tools, `WebSearch`, `Task`, `TodoWrite`, `LS`) still run without the policy when a user's or a project's `allow` rule names them. Their calls are not checked for paths, commands or approvals. A cloned repository's `.claude/settings.json` can allow such a tool.

**Known limit, not fixed in this version: hooks.** The user's and the project's `PermissionRequest` hooks of Claude Code can approve a call before Bandito does. Bandito does not read or change them.

**Asked: what cannot be known, or names Bandito's files without a path.** The rule is: a path, folder or command that cannot be worked out is asked about, never allowed. In risky and always modes a call is asked about when:

- a word the command uses cannot be expanded (a variable not set on the line, `$1`, `${X:-y}`, a substitution, an unknown user) and it can name a file: it is the program itself, a redirect target, or an argument of a command that reads or writes files (`cat`, `less`, `head`, `tail`, `grep`, `sed`, `awk`, `jq`, `sqlite3`, `strings`, `xxd`, `base64`, `openssl`, `nc`, `socat`, `tar`, `cp`, `mv`, `rm`, `python`, `node`, `sh`, `source`, …). `echo "$PATH"`, `printf '%s' "$HOME"` and `git commit -m "$MSG"` are allowed. Inside single quotes, `$` is literal: `awk '{print $1}' f` is not unknown;
- a folder the command runs in is unknown (after `cd -`, `popd` with nothing pushed, a `cd` in a pipeline, or a `cd` to an unknown folder), and the command takes path arguments (a plain name in `cd $X && rm a` counts; `cargo test` and `echo` do not);
- `source FILE` or `. FILE` where FILE is unknown, or known but outside the agent's folders (`source ~/.bashrc`). A file inside the folder is allowed (`. .venv/bin/activate`): what it contains is not read, as with `python script.py`;
- a path argument (or a redirect target) whose file name is one of Bandito's file names (`./bandito.db`, `~/x/agent.sock`) is asked about, not refused. A word without a slash is text, not a path: `grep -rn agent.sock daemon/src` and `git commit -m "... bandito.db ..."` are allowed.
- a line contains brace expansion (`{a,b}`, `{a..b}`), a zsh `=word`, a substitution, a process substitution, a heredoc, `eval`, a variable or glob as the program, an unclosed quote, a pipe into a shell or interpreter with no script, inline code from a pipe, a line over 64 KiB, or nesting deeper than 8.

Never mode allows what is only asked about; it still refuses what is proven to reach Bandito's files.

**Risky (default): a safety net, not a boundary.** `risky` reads the command line itself (`daemon/src/shell.rs`: quotes, `&&`, `;`, pipes, redirections, heredocs, `$(…)`, `$'…'` escapes, `sh -c`, subshells, and wrappers such as `sudo`, `env`, `timeout`, `nice`, `busybox`, `xargs` and `find -exec`, which are taken off so the command underneath is judged). It asks the human when a command means something risky, by meaning and not by prefix:

- `git`: `push` (any form), `reset --hard`, `clean` with `-f`, `branch -D`, `checkout`/`restore .`, `filter-branch`, `filter-repo`; a config key that runs a program (`core.sshCommand`, `core.pager`, `core.editor`, `core.hooksPath`, `core.fsmonitor`, `alias.* = !…`, `filter.*`, `diff.*.textconv`, `credential.helper`, `sequence.editor`, `gpg.program`, `ssh.variant`, `protocol.*.allow`, `uploadpack.*`, `receive.*`) given with `-c` or `git config`, and the environment variables `GIT_SSH_COMMAND`, `GIT_PAGER`, `GIT_EDITOR`, `GIT_EXTERNAL_DIFF` and similar: `risky: git config exec`;
- `rm` with a recursive flag, `find -delete`, `shred`, `dd of=`, `mkfs*`, `truncate`, `chmod -R`, `chown -R`;
- publishing: `npm`/`pnpm`/`yarn publish`, `cargo publish`, `twine upload`, `gem push`; deploys: a program or script whose name starts with `deploy` (`./deploy.sh`), `npm|pnpm|yarn run deploy*`, `make deploy*`, `cargo xtask deploy*`, `fly`/`wrangler`/`firebase`/`gcloud deploy`, `vercel deploy` and `vercel --prod`;
- `kubectl delete|apply|replace|patch|drain|rollout`, `helm install|upgrade|uninstall|delete`, `terraform apply|destroy`, `pulumi up|destroy`, `docker system prune`, `docker volume rm`, `docker rm -f`, `docker compose down -v`;
- SQL `drop table`, `drop database`, `truncate table`, `delete from` anywhere in the line (matched in the raw text on purpose);
- `shutdown`, `reboot`, `halt`, `poweroff`, `systemctl` except `status`/`show`/`list-*`/`is-*`, `launchctl`, `crontab` except `-l`, `at`, `systemd-run`, `useradd`, `usermod`, `passwd`, `visudo`;
- sending data out: `curl` with `-d`, `-F`, `-T`, `--data*`, `--form*`, `--json` or a write method (`-X POST`, `-XPOST`, `-sSd`), `wget --post-*`, `scp`, `rsync` to a remote host, `nc`, `ncat`, `socat`, `telnet`, `ssh` with a command.

The reason reads `risky: <rule>`. Two more asks: a write (redirect, or `cp`, `mv`, `rm`, `tee`, `touch`, `mkdir`, `sed -i`, `curl -o`, `wget -O`, `tar -C`, `unzip -d`, `rsync`'s destination, the start paths of a `find -exec`) to a path outside the agent's folders (`writes outside <folder>`); and any part of the line the reader cannot follow, as above (`can't check: <reason>`). Everything else is allowed.

**Credential folders.** A read with the `Read`, `Grep` or `Glob` tool is not a write, so it is allowed anywhere, outside the agent's folders too, unless it is a credential read below. The folders and files `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `~/Library/Keychains`, `~/.netrc`, `~/.docker`, `~/.kube`, `~/.git-credentials`, `~/.npmrc` and `~/.pypirc` hold credentials. In risky mode a call that reaches one is asked about, reads included, with the reason `reads credentials: ~/<folder>`:

- the `Read`, `Grep` or `Glob` tool on a path in one of them, or a `Glob` pattern that starts in one (`~/.aws/*`);
- a shell command with a word in one of them, after `~`, `$HOME` and `${HOME}` are expanded (`cat ~/.ssh/id_rsa`, `cp $HOME/.aws/credentials /tmp/x`, `ls ~/.ssh`, `cat < ~/.config/gh/hosts.yml`). The folder the command runs in counts, so `cd ~/.ssh && cat id_rsa` is asked about, and so does the part after `=` or `:` (`--file=$HOME/.ssh/k`), and a command inside `sh -c`;
- a command that reads a whole folder that holds one (`tar czf h.tgz ~/Library`, `cp -r ~/.config …`). Such folders are refused by the protected rule above anyway, because the Bandito service files sit under them.

Matching is by whole path components, case-insensitively. Project files such as `.env` are not on the list. Never mode allows these calls; always mode asks about every call. The data folder is refused in every mode, before this check. Limit: the check reads the command line (see *What is modelled* below). A credential folder reached through an interpreter's inline code (see below), or through a script's contents, is not seen.

**Inline code.** An interpreter given code on the line runs code the policy does not read: `python -c` (and `-Sc`), `node -e` and `-p`, `ruby -e`, `perl -e` and `-E`, `php -r`, `bun -e`, `deno eval`. A credential folder named in such a line is asked about (`reads credentials: ~/<folder>`), as a whole path: `~/<folder>`, `$HOME/<folder>`, `${HOME}/<folder>` or the home folder's absolute path followed by it. Bandito's folder is asked about by its absolute path or as `~/.bandito`. Names in other forms (`os.environ['HOME'] + '/.ssh'`, `os.path.join(home, '.ssh')`) are not seen: this is a known gap. `-r` is php's flag only (pip's `-r requirements.txt` and node's `-r module` run no code on the line). A script file given by name is not read: its contents are not seen.

**Links.** A path is judged as written and also where its symbolic links lead. Links are followed only for paths inside the home folder or the agent's own folders: a path elsewhere (a network or external volume) is judged as written and is not looked up. The path is resolved one component at a time: a link is replaced by its target (an absolute target restarts from the root), and `..` is applied to the resolved folder after the link, so `lnk/../bandito.db` with `lnk` pointing at Bandito's `logs` folder is the data folder (refused). A link whose target does not exist yet is still a link: a write through it is a write to its target, judged by where that target lies (`writes outside <folder>` when it is outside the project). The credential folders and Bandito's paths are resolved when the policy is built; any other path at most once per decision.

Agent rules (`allow` / `ask` / `deny`) are checked after the protected rule and before the risky checks, and they win over the risky checks. None of them can allow a protected call. "Always allow here" stores the exact command, with `*` escaped so the rule matches only that command; a command with a part that cannot be known is not remembered.

A panic while deciding is logged without the command and becomes `Ask("policy error")`.

**What is modelled, and what is not.** Modelled: quoting and escapes (including `$'…'` and `$"…"`), redirections, `~`, `~user`, `$HOME`, `${HOME}`, `$BANDITO_HOME`, variables set on the line (assignments, `export`, `unset`, `read`, prefix assignments for their own command only), `cd`, `pushd`, `popd`, subshells `( … )` (state restored after them), pipelines (`cd` or an assignment on one side of a pipe leaves the state unknown), wrappers, `sh -c` and `find -exec` bodies, `xargs`. Not modelled, so the call is asked about or only partly checked: the code run by an interpreter (`python -c`, `node -e`, `perl -e`), the contents of a script file (`./deploy.sh` is judged by its name only), npm and make script bodies, shell functions, aliases and startup files, `PATH` lookups (a program named `rm` may not be the system's), symbolic links (paths are compared lexically, the file system is not read), `$PWD`, `$OLDPWD`, `cd -`, parameters set by the shell itself, and the environment of the agent's shell beyond `HOME` and `BANDITO_HOME`.

**The folder between calls.** A session's shell keeps the folder its last Bash call left it in: a `cd` on the line holds for the next call of the same session, and a new session starts in the agent's folder. The folder moves only when the line goes ahead: at once when the policy allows it, or on the user's yes when it was asked about. A refused line, or one the user denies, leaves the folder where it was. The folder is only known while the policy can follow the line. A line that runs `command` or `builtin`, `eval`, `source` or `.`, or `exec`, or that has a part the reader cannot follow (a brace expansion, a substitution, a subshell it cannot close), leaves the folder unknown. A `cd` inside `command cd x` or `builtin cd x` still moves the folder for the commands after it on the same line. While the folder is unknown, a Bash call is judged from both the agent's folder and the home folder, and the most careful verdict wins: a relative path can then name the data folder or a credential folder whichever way the shell went. The home folder of an unknown shell is only assumed, so a recursive reach from it into Bandito's files (`grep -r foo .`, `find . -name x`, `rg`, `git grep`) is a question (`can't check: unknown folder`), in risky and always modes; only a direct name of the data folder (`cat .bandito/x`) is refused. An explicit absolute `cd` (`cd /path`) brings the folder back to known. A subshell's `cd` does not count.

**Limits, stated plainly.** Risky mode guards against an agent making a mistake. It does not stop an agent that is trying to get around it: an interpreter, a script or a symlink can reach what the reader does not follow. The data folder is the one the daemon runs in: `--home`, else `BANDITO_HOME`, else `~/.bandito` (the daemon passes it to the policy at start). The real boundary is a separate machine or a workspace container (see [Workspaces](#workspaces)).

**Protection boundary.** The policy checks tool calls: the tool, the text of its command, and the paths it reaches (followed through `~`, `$HOME`, `${HOME}`, links, and the forms named above). It does not check what the programs it runs do inside. A script the agent wrote and runs (`python3 x.py`, `npm test`, a `build.rs`, a git hook, a Makefile target) can read anything the server user can read, and nothing on the command line shows it. Symbolic links are followed only inside the home folder and the agent's own folders. A path elsewhere (a network share, an external volume) is judged as written, with no file-system call, so a link there is not followed: a deliberate limit, for speed on network volumes and for paths that are not Bandito's. That is the boundary of this check, and it is not a sandbox. For isolation use a container workplace ([Workspaces](#workspaces)); on macOS an agent's shell can also run under the Seatbelt profile of the [macOS sandbox](#macos-sandbox), which is a second layer and not a substitute for the container.

The daemon can also ask the human itself, for something no runtime asked about (a risky browser click, see [Browser](#browser)). Such a request goes into the agent's feed like any other approval: `approval.requested`, answered with `approvals.resolve`. Nothing is remembered from it. No answer within the time limit denies it, and so does a stop of the agent while it waits. This works the same for every runtime.

A pending approval blocks only that agent. Approvals time out after 24 h → deny.

## Store (SQLite)

- `agents(id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at, fallback_runtime, fallback_model, active_runtime, paused, use_personal_settings, avatar_color, avatar_face, capabilities)`: `avatar_color` and `avatar_face` are the [avatar](#capabilities) (both NULL = derived from the name); `capabilities` is a JSON array of [capabilities](#capabilities), NULL = all. `fallback_runtime`, `fallback_model` and `active_runtime` are the [fallback subscription](#fallback-subscription); `active_runtime` NULL means the primary `runtime`. `paused` is the [pause](#pause) flag
- `events(seq INTEGER PRIMARY KEY, agent_id, ts, kind, payload JSON)`
- `approvals(id, agent_id, call_id, tool, title, payload JSON, status, decision, created_at, resolved_at)`
- `rules(id, agent_id NULL, pattern, action)`
- `schedules(id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at)`
- `devices(id, name, token_hash, created_at, last_seen_at)`; `pairing(code_hash, expires_at)`
- `checkpoints(id, agent_id, sha, label, kind, turn_id, created_at)`: points in an agent's folder history (see [Changes](#changes))
- `secrets(name, value, agents, created_at, updated_at)` for API keys, file mode 0600 (keychain/age later); see [Secrets](#secrets)
- `workspaces(id, name, kind, image, cpus, memory_mb, network, mounts, created_at)`: where an agent's CLI runs. The row `shared` is created by the migration and always exists. `agents.workspace_id` (default `shared`) says where each agent runs; see [Workspaces](#workspaces)

Migrations: numbered SQL files embedded in the binary, applied by `PRAGMA user_version`.

## RPC

JSON-RPC 2.0. Same methods on every transport.

- `devices.list` returns the paired devices as `{id, name, created_at, last_seen_at, current}`. `current` is `true` for the device whose token made the request; the owner's CLI is no device, so every row is `false` for it. Old apps ignore the field.
- Chat: `forms.answer{form_id, action: "submit"\|"reject", values?, comment?}` (`values` checked against the form, `already_answered` on a second answer), `forms.list{agent_id?, status?}`, `messages.react{agent_id, seq, emoji: string|null}`, `attachments.upload{agent_id, name, data_base64}` (returns `{path, name, size, mime}`). `agents.send` also takes `reply_to?: seq` and `attachments?: [path]`. See [Forms](#forms), [Reactions](#reactions), [Replies and attachments](#replies-and-attachments).
- Requests: `daemon.info`, `runtimes.status` (each entry has `supported_capabilities`, see [Capabilities](#capabilities)), `runtimes.models{runtime?, refresh?}` (see [Runtime models](#runtime-models)), `agents.list|get|create|update|delete` (`update` takes `paused` too, see [Pause](#pause)), `agents.send{agent_id,text}` (replies `{queued: true}` when the agent is paused), `agents.interrupt`, `agents.new_chapter{id}` (owner only: starts the agent's next chapter now, with the same wrap-up as a context close; a running turn finishes first), `agents.pause_all{paused}`, `events.since{seq,limit,agent_id?}`, `approvals.list|resolve{approval_id,decision,remember}`, `rules.list|set|delete`, `schedules.list|create|update|delete|run_now`, `devices.list|revoke`, `pair.redeem{code,device_name}` (only unauthenticated method), `term.list|open|input|resize|rename|close|attach|detach` (see Terminals), `fs.*` (see [Files](#files)), `changes.checkpoints|diff|file|restore` (see [Changes](#changes)), `secrets.list|set|delete` (see [Secrets](#secrets), `host.stats|history|processes|ports|kill`, `setup.status|install|job` (see [Setup](#setup)), `commands.list|install` (see [Commands](#commands)), `browser.start|status|stop|control|touch` (see [Browser](#browser)), `workspaces.list|create|update|delete|start|stop` (see [Workspaces](#workspaces)), `daemon.logs{lines,level}` (see [Logs](#logs)). `agents.create|update` also take `avatar` and `capabilities` (see [Capabilities](#capabilities)). `browser.agent.*` is for the crew MCP on the server only.
- Notifications (server → client): `event{seq, agent_id, kind, payload, ts}` for every event including `message.delta`; `term.output|gap|exit|closed` for attached terminals (see Terminals).

## Transports (connect any way you like)

The daemon always listens on:

1. Unix socket `~/.bandito/bandito.sock` (0600): the owner's CLI. Only processes that are not under the daemon may connect, see [Trust model](#trust-model).
2. Unix socket `~/.bandito/agent.sock` (0600): the crew servers of agents. Each connection must open with `daemon.hello` carrying its session token.
3. `127.0.0.1:7878` HTTP + WebSocket (`/v1/rpc`, `/v1/health`, `/v1/files/raw`, `/v1/tunnel`, `/v1/browser/*`). Token required.

WebSocket upgrades that carry an `Origin` header are refused: native apps don't send one, browsers always do, so a web page can't drive the daemon through the user's browser. Unix socket paths are limited to ~104 bytes on macOS, so keep `BANDITO_HOME` short.

Optional: `listen = ["0.0.0.0:7879"]` with TLS (self-signed cert generated on first start; the app pins its SHA-256 fingerprint at pairing).

Pairing: `bandito pair` prints a 6-word code, a QR and a `bandito://pair?...` link (host hints + cert fingerprint). `pair.redeem` swaps the one-time code (10 min) for a device token; the app keeps it in the Keychain. Tokens are stored hashed and can be revoked.

Ways the Mac app reaches a server, all ending in the same WebSocket:

| Method | How |
|---|---|
| This Mac | local socket, no pairing |
| SSH | app runs system `ssh -N -L` (your `~/.ssh/config`, agent, keys, jump hosts); pairing happens over the same SSH session automatically; can also install the daemon for you |
| Tailscale | `ws://<machine>.<tailnet>.ts.net:7878` or `tailscale serve` HTTPS; daemon option `listen = ["tailscale"]` binds to the 100.x address only |
| Direct | host:port, TLS with pinned fingerprint |
| Cloudflare Tunnel, WireGuard/ZeroTier/Netbird, reverse proxy | any URL that ends at the daemon port; token auth |
| Bandito Relay | later: outbound-only connection from the daemon through bandito.dev, end-to-end encrypted |

## Trust model

Who may call the daemon, and what. One list in `daemon/src/rpc/mod.rs` (`allowed`) decides, and it is checked first in every dispatch and before the event stream.

**Two sockets, both mode 0600.** Both are created under umask `0077`, so there is no moment when they are more open.

- `bandito.sock` is the owner's CLI. A connection is refused when the calling process runs under the daemon: agents, their shells and tools, and the terminals and apps the daemon opened. The caller's pid comes from the socket (`SO_PEERCRED` on Linux, `LOCAL_PEERPID` on macOS), and the parent chain is walked (`/proc/<pid>/stat` on Linux, `proc_pidinfo` on macOS) up to pid 1. A caller whose chain cannot be read is refused too (fail closed, with a warning). On Linux the daemon is a child subreaper, so a process that double-forks away is still re-parented under it. The daemon also reaps those children: every 10 s it reads `/proc`, and a zombie child that is still a zombie at the next scan is waited for by its pid (the first scan only marks it, so a child whose owner waits for it gets the chance first). Children that have an owner who waits for them (runtime CLIs, terminals, the screen and the browser) are registered and left alone; an owner's exit status is never taken away. A CLI that exits while a process it left behind keeps its stdout open is reported with its real exit code after one second; that process is then killed with the rest of the CLI's group. Consequence: `bandito pair` run from a terminal that the Bandito app opened does not work. Use a terminal of your own.
- `agent.sock` is for the crew servers of agents. The first request must be `daemon.hello {"agent_token": "..."}`. Without a valid token the reply is UNAUTHORIZED and the connection closes.

**Agent session tokens.** Each runtime session (Claude, Codex, Grok, and a fallback runtime) gets its own token when it starts: `bat_` plus 32 random bytes in base64url. The daemon keeps only the SHA-256 of each token, in memory. Two places carry the token, and neither puts it in an argument list (`ps` shows argument lists to other users): the CLI's environment (`BANDITO_AGENT_TOKEN`), and a file under `$BANDITO_HOME/run/` (`agent-<random>.token`, mode 0600, written through a temporary file and a rename). The crew server is started with `--token-file <that file>`. Its MCP config for Claude is a file too (`agent-<random>.mcp.json`, mode 0600), passed to `--mcp-config` by path. The run folder is mode 0700. Ending the session revokes the token and removes both files. Starting the daemon removes what a previous one left, and a restart revokes all tokens. The agent is the one its token names: an `agent_id` or `from` in the params must match it, or the call is refused.

| Peer | How it connects | May call |
|---|---|---|
| Anonymous | any transport, not paired | `daemon.hello`, `pair.redeem` |
| Device (paired app) | WebSocket with the device token | everything except the agent tools |
| Local (owner's CLI) | `bandito.sock`, not under the daemon | everything except the agent tools |
| Agent | `agent.sock` with a live token | `daemon.hello`, `crew.list`, `crew.send`, `forms.agent.ask`, `messages.agent.react`, `history.day`, `history.search`, `browser.agent.{back,click,open,press,screenshot,snapshot,switch,tabs,type}`, `screen.agent.{click,key,launch,move,screenshot,scroll,type}`; for the agent its token names (see the caveat below) |

The agent tools (`crew.send`, `forms.agent.*`, `messages.agent.*`, `history.*`, `browser.agent.*`, `screen.agent.*`) are for agents alone. The owner's CLI and the apps may not call them, so nothing that speaks as the owner can pass for an agent. Agents may call none of the owner's methods: rules, approvals, pairing, devices, secrets, agent create/update/delete, workspaces, setup, and `commands.install` at user scope.

**Host header.** The check depends on the address the daemon listens on. On a loopback listener (`127.0.0.0/8` or `::1`), HTTP and WebSocket routes accept only the `Host` names `127.0.0.1`, `localhost`, `[::1]` and `::1` (the port is ignored), plus the names in `allowed_hosts` of `$BANDITO_HOME/config.json`. Any other name, and a request without `Host`, gets 421 Misdirected Request. This blocks DNS rebinding from a web page. A reverse proxy or tunnel on the same server connects to loopback and sends its own name, so put that name in `allowed_hosts`. On a listener on any other address (for example `0.0.0.0` or a Tailscale address) the `Host` is not checked: the bearer token and the refused `Origin` header protect it. The config file is optional. It is a JSON object with two keys: `allowed_hosts` (a list of host names without port or path) and `agent_sandbox` (see [macOS sandbox](#macos-sandbox)). An unknown key or a bad name stops the daemon at start.

**`pair.redeem` rate limit.** Failures count in a 10-minute window: at most 100 for the whole daemon, and 5 per source (the client IP on WebSocket, `local` on `bandito.sock`). A refused call gets RATE_LIMITED.

**What this does not stop.**
- A process of the same user that is not under the daemon passes as the owner. Examples are one started by `systemd-run --user`, by cron, or in a tmux server the owner already runs. The check asks "is this under the daemon", not "is this trusted".
- On macOS a double-forked process is re-parented to launchd, so it is not seen as the daemon's. The [macOS sandbox](#macos-sandbox) closes the known channels for agent sessions: their processes, orphans included, cannot reach `bandito.sock`. It is a layer, not a boundary (see there).
- Agents of the same user can read each other's token files: on Linux, and on macOS when the sandbox is off (`agent_sandbox: false`). An agent that reads another agent's token can speak as that agent (`crew.send`, `history.*`). The sandbox on macOS denies the other sessions' files.
- An agent with shell access runs as the daemon's user and can do what that user can on disk. The token only opens the agent tools, but the agent can read its own environment. For real isolation use a container workspace (see [Workspaces](#workspaces)), not these checks.

**What agents share.** The browser (one per workspace) and the screen (one per workspace) are shared by all agents in that workspace, and the daemon starts them, so they run outside any agent sandbox. An agent can drive them through the browser and screen tools, but it cannot run commands through them. Anything an agent does in the browser or on the screen is visible to the other agents of the workspace.

**Agent sessions in containers.** A container is the isolation for an agent in a container workspace. Agents in containers get no crew server, so they have no agent tools (`crew.send`, `history.*`, browser and screen tools), and `agent.sock` is not mounted. Their session token still goes into their environment, but nothing reads it there. This is a known limit: such agents cannot use the crew tools at all.

## macOS sandbox

On macOS, the Claude, Grok and Codex sessions of the shared workspace run under `sandbox-exec`, with a Seatbelt profile that the daemon writes for each session. The processes a session starts run under the same profile. This is an additional layer. It closes the channels we know that start something outside a session. It is not a boundary (see below).

**What the profile closes.**
- Starting programs that hand work to other services: `open` (Launch Services), `osascript` (Apple events), `launchctl`, `lsappinfo`, and the scheduler programs `crontab`, `at`, `batch` and `cron`. Their exec is refused, and so is a Launch Services connection (`mach-lookup` of `launchservicesd`).
- Apple events: `appleevent-send` is denied. `osascript` cannot run at all under the profile, so `osascript -e 'return 1'` fails there too.
- Autostart and later execution: writes to the login files (`.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`, `.bashrc`, `.bash_profile`, `.profile`, `.ssh/rc`, `.ssh/authorized_keys`), to `~/.config/fish`, to `~/Library/LaunchAgents`, and to the background task manager's folder under `~/Library/Application Support`.
- The daemon's data folder (`$BANDITO_HOME`): nothing in it is readable or writable, except the session's own two files (its token file and its MCP config). Connecting to `bandito.sock` is denied, and `agent.sock` is allowed. A denial on the folder does not stop a connect to a unix socket, so the network rule is the one that counts. Writing the daemon's binary is denied.

**What the profile does not close.** Everything else stays open: project folders, the network, and the rest of the user's files. The profile is a list of known channels, not an allowlist, and it is not a boundary. A copy of a system binary that is not on the list, an unknown channel, or a process of the owner's own shells is outside what it checks. The real isolation is a container workspace (see [Workspaces](#workspaces)), or in future a separate macOS user.

**Codex.** Codex is wrapped in the same profile, and its own sandbox is turned off: the `-c sandbox_mode="danger-full-access"` override, and the same `sandbox` value for its threads (checked against `codex-cli` 0.161.0). Approvals stay with Codex's approval policy (`untrusted`), and so with Bandito's policy. A nested sandbox cannot be applied inside a sandbox (`sandbox_apply: Operation not permitted`), which is why Codex's own is the one that goes.

**Containers** are not wrapped: they are isolated already.

**Paths.** A path that is not valid UTF-8 cannot be written into a profile or an argument list faithfully. Such a session does not start, with an error that names the path. Nothing is converted lossily.

**Switching it off.** `"agent_sandbox": false` in `$BANDITO_HOME/config.json` turns the sandbox off for new sessions. It is on by default. It has no effect on Linux.

**Checked on macOS** (tests in `daemon/src/runtime/sandbox.rs`): a read of the database is denied; a connect to `bandito.sock` is denied, also from an orphan started by a shell; a connect to `agent.sock` and a read of the own token file work; other sessions' token files are denied; the crew bridge (`bandito mcp`) starts under the profile, so it never creates or stats the data folder; `open` and `launchctl` cannot start; an Apple event sent by a small program is refused under the profile and accepted without it; writes to `~/.zshrc` and `~/Library/LaunchAgents` are denied in a temporary home, and a file elsewhere in the home stays writable; writes into the project, `git`, `node` and `curl` work; `nc` to the network works where there is a network.

**Not verified.** The Claude and Grok CLIs may run their own shell tool under `sandbox-exec`. Then their commands fail inside this profile, since nested sandboxes are refused. This was not tested with the real CLIs; check it before relying on the sandbox.

## Scheduler

Cron expressions with a time zone. On fire: `agents.send` with `source:"schedule"`. Missed runs while the daemon was down run once on start if missed by less than 1 h. A run that falls due while its agent is [paused](#pause) is skipped (logged): it is not recorded as a run, and the next occurrence is set as usual.

## Pause

A paused agent (`agents.update {paused: true}`, or all agents at once with `agents.pause_all {paused}`) stops working, and keeps its history:

- A message sent to it (`agents.send`, a crew message, a schedule's run) is written to the thread at once, and the reply is `{queued: true}`. No session starts. The message waits in the agent's queue.
- A pause interrupts the running turn, as `agents.interrupt` does. The queue stays.
- A resume (`paused: false`) starts the queued messages one turn at a time, as they would have run without the pause. A message that could not start (for example its runtime is not installed) is shown in the thread as usual, and the resume itself still succeeds.
- Scheduled runs of a paused agent are skipped (see [Scheduler](#scheduler)).
- The flag is in the store (`agents.paused`), so the apps see it in `agents.list|get`. The queue is in memory: messages held at a daemon restart are lost, as messages waiting for a turn already are. They stay visible in the thread.

`agents.pause_all` is for the owner's CLI and the apps. It returns how many agents changed. Clients show the pause controls when `daemon.info.features` contains `"pause"`.

## Personal settings

A Claude agent's CLI loads only the project's and the local settings by default (`--setting-sources project,local`). The owner's own user settings stay out: their `~/.claude/CLAUDE.md`, hooks, plugins and MCP servers. Otherwise an agent answers with the owner's private instructions (its projects, its rules).

`agents.create|update|get` take and return `use_personal_settings` (default `false`, stored in `agents.use_personal_settings`). `true` restores the CLI's default: all setting sources load. The flag is read when a session starts, so a change reloads the running session like the other config. Codex and Grok are not changed by this flag (see their runtime notes).

## Capabilities

An agent has a list of capabilities, the things it may use: `terminal` (the shell), `files` (changing files; reading stays), `browser`, `team` (the crew: `crew_list`, `crew_send`) and `screen`. `agents.create` and `agents.update` take `capabilities` as a list of those names. On create, `null` or a missing field means all of them. On update, a missing field keeps the list, `null` gives all of them back, and `[]` means none. An unknown name is `INVALID_PARAMS`. `agents.get`, `agents.list`, `agents.create` and `agents.update` return `capabilities`, `null` for all.

A change applies from the next session, as a model change does: a running session is reloaded like the other config. What each capability switches off:

- Claude: without `terminal`, `Bash` is denied; without `files`, `Edit`, `Write`, `MultiEdit` and `NotebookEdit` are denied (see [Runtimes](#runtimes)). Claude Code applies these deny rules before each tool call; an agent without `terminal` could not run a shell command in a live check on QA.
- Every runtime, through the crew MCP: a tool of a missing capability is not listed, and a call to it is refused as an unknown tool.

Only Claude can switch `terminal` and `files` off. Grok and Codex cannot, so `supported_capabilities` in each `runtimes.status` entry is `browser`, `team` and `screen` for them (Claude has all five; the API runtime is not served and has none). The app shows the other two as unavailable for those runtimes. `agents.create` and `agents.update` refuse a list that leaves out `terminal` or `files` for Grok or Codex, with `INVALID_PARAMS` and the message `<runtime> не умеет запрещать <capability>` (for example `grok не умеет запрещать terminal`). The check uses the runtime the agent will run on after the patch. A list that keeps them, or `null`, is accepted: it means the agent may use them, and nothing is promised beyond that.

The two extra layers below are best effort. They are **not guarantees**: an agent on Grok or Codex can still run a shell command or change a file.

- Grok, as an extra layer: a permission request Grok sends for a command (ACP kind `execute`) is refused, and one for a change of files (`edit`, `delete`, `move`) is refused, when the agent lacks the capability. The refusal is an automatic reject: the owner gets no card. Grok asks only when its own permission mode asks. With `permission_mode = "always-approve"` in its config (`~/.grok/config.toml`), it runs commands without asking, and those are not refused. The daemon passes Grok no permission mode (`grok agent stdio` has no flag for it).
- Codex, as an extra layer: without `files`, the thread's sandbox is `read-only` (`sandbox_mode`, set with `-c` and in `thread/start`). That applies only where Codex's own sandbox is in charge. On macOS, with the daemon's own sandbox (on by default for shared-workspace agents), Codex's sandbox stays off, because a macOS sandbox does not nest; there the file-change approvals Codex asks for are declined, with no card. Whether Codex asks for every file change is not verified. Agents stored with `files` off before this rule keep the read-only sandbox where it applies.

`avatar` is `{color, face}` or `null`, which means the app derives it from the agent's name. The daemon keeps both names trimmed and 1 to 32 characters, and does not check them against the app's list. A change of the avatar reloads nothing.

## Logs

`daemon.logs {lines?, level?}` returns the newest lines of the daemon's own log, for the app's journal view. `lines` is 1–2000 (default 500); `level` is the lowest level to show: `info` (default; debug and trace lines are left out), `warn` or `error`. The reply is `{source, lines}`, where `source` is `journald` or `file`.

Where the lines are: a systemd user unit writes to the journal (read with `journalctl --user -u bandito.service -o cat`), and a launchd agent or a background process writes `<home>/logs/daemon.log`. The reader scans the last 4 MB of the file, or the last 10 000 journal lines, then keeps the newest `lines` lines at the level. A line without a level takes the level of the line before it, so a wrapped error stays with its error. Colour codes are removed.

Clients show the journal when `daemon.info.features` contains `"logs"`.

Before a line is returned, every secret value is replaced as in [Secrets](#secrets) (`••••NAME`), and the secret part of Bandito's tokens (`bdt_` and `bat_`) becomes `••••`. Only the owner's CLI and the apps may call it.

## Crew

`bandito mcp` is an MCP server (stdio) injected into every agent: `--mcp-config` for Claude, `mcp_servers` config for Codex, `mcpServers` in ACP `session/new` for Grok. It answers `initialize` with the client's protocol version when it is one of `2025-06-18`, `2025-03-26`, `2024-11-05`, otherwise with `2025-06-18`. Input lines over 1 MB get a parse error and are skipped.

Tools today: `crew_list` and `crew_send{to, message}` (becomes `message.user` with `source:"crew"` for the target). Chat tools, for every agent whatever its capabilities: `ask_form` (see [Forms](#forms)) and `react{seq?, emoji}` (see [Reactions](#reactions)). `report{text}` (shows in the user's inbox) is later, not in the MVP yet. `crew.send` over RPC is accepted only from an agent's session on `agent.sock`, and only as that agent; paired apps can call `crew.list` only. See [Trust model](#trust-model).

Loop guards: every crew message belongs to a chain, which starts with each user or schedule message. The daemon counts three limits:

- depth: a chain stops after 8 hops without a human (`MAX_CREW_HOPS`);
- per turn: one turn sends at most 3 crew messages (`MAX_CREW_SENDS_PER_TURN`);
- per chain: a chain carries at most 20 crew messages in total, across all its turns (`MAX_CREW_MESSAGES_PER_CHAIN`).

A refused `crew_send` comes back to the agent as a tool error that tells it to report to the user. The counters are in memory: a daemon restart resets them, and they are dropped all at once when more than 10 000 chains are tracked. A crew message sent while the agent has no running turn is not counted against the per-turn limit.

These limits stop accidental loops. They are not a security boundary: an agent with shell access runs as your user and can do anything you can.

The daemon starts the crew server with `--capabilities <list>` when the agent has capabilities set (see [Capabilities](#capabilities)); the server then lists only the tools of those. The crew tools need `team`, the browser tools `browser`, the screen tools `screen`. The history tools need none.

Browser tools are on the same server, through the same crew MCP: `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_press`, `browser_back`, `browser_screenshot`, `browser_tabs`, `browser_switch`. They are described in [Browser](#browser). A `browser_click` that needs the person's approval waits over MCP for as long as the approval may take (10 minutes, plus a margin), not for the 30 seconds of an ordinary call.

## Browser

The server runs one Chrome per workspace (`shared` by default). The app watches it, and agents drive it, through the same daemon. Code: `daemon/src/browser.rs` (manager, approvals), `daemon/src/cdp.rs` (DevTools client, snapshot), `daemon/src/cdp_pipe.rs` (pipes and relay), `daemon/src/rpc/browser.rs` (methods and routes). Feature string: `"browser"`. The screen feature (Xvfb) is separate; the browser runs `--headless=new` for now.

**Start.** `browser.start{workspace?}` finds `google-chrome`, `google-chrome-stable`, `chromium` or `chromium-browser` on `PATH`, and on macOS `/Applications/Google Chrome.app` first. It starts Chrome in its own process group, with `--headless=new --remote-debugging-pipe` and the profile `<data dir>/workspaces/<workspace>/browser` (`<data dir>` is `$BANDITO_HOME` or `~/.bandito`). Chrome opens no TCP port. The DevTools protocol runs over two pipes: Chrome reads commands on fd 3 and writes answers and events on fd 4, each message JSON followed by a NUL byte. The daemon sets the pipes up in the child with `pre_exec` (`dup2` onto 3 and 4). Chrome's output goes to `browser.log` in the workspace folder. The daemon waits up to 10 s for `Browser.getVersion` to answer. Without a browser the error has `reason: "missing_component"` and `component: "browser"`, and the app offers the install from setup.

**Relay.** One task owns both pipes (`cdp_pipe.rs`), and every client is a view on it. A client's command gets a new id from the relay, and the answer goes back with the client's own id, so two clients may use the same ids. A client may have 256 commands unanswered; the 257th gets `{"id", "error": {"code": -32000, "message": "too many pending commands"}}`. A session event (one with `sessionId`) goes to the client that owns the session. A browser-level event goes to every browser-level client. A tab client attaches its tab when it is made (`Target.attachToTarget`, flattened), detaches it when it goes (`Target.detachFromTarget`), and sees plain CDP: no `sessionId` on its messages. When the tab closes, its client gets `Target.detachedFromTarget` and then its connection ends. A client whose queue of 1024 messages is full is disconnected, not waited for. A message from Chrome over 64 MiB, or one that is not JSON, is treated as a crash: the pipe closes, the browser is stopped, and the next call starts it again. Agents (`browser.agent.*`) use the relay directly, with a tab client per call.

**Page and browser rules.** A page client is one tab's view, and it may not reach the browser around it. Its commands in `Target.*`, `Browser.*`, `Storage.*` and `SystemInfo.*` are refused, as are any `params.targetId` and any `params.sessionId` (the one exception: `Page.screencastFrameAck`, whose `sessionId` is a frame number). A refusal is `{"id", "error": {"code": -32002, "message": "method not allowed for a page client"}}` (or `params.sessionId`/`params.targetId is not allowed for a page client`). A browser client may name only its own sessions: `Target.detachFromTarget` and `Target.sendMessageToTarget` with another client's `params.sessionId` are `-32001 unknown session`. `Target.closeTarget` is refused (`-32001`, "the tab is attached to another client") when a session on that tab belongs to another client; a tab nobody attached can be closed. A device is the owner of its browser, so its raw CDP is not checked against `browser.control`'s `controller`: that is by design. When a session's target detaches, the relay forgets the session whoever owns it.

**Budgets.** A client may have 256 MiB of messages queued (the sum of their lengths); past that it is disconnected as slow, like one whose count of 1024 messages is full. Commands waiting for the pipe may total 128 MiB; a command past that is refused with `{"id", "error": {"code": -32000, "message": "too many bytes waiting for the browser"}}`, not queued. The relay never waits on a client or on the pipe.

**The app.** The app speaks DevTools over the routes below, with its device token, and runs a CDP screencast on the tab socket. The daemon does not relay frames. `browser.status` answers `{running, cdp, pid, started_at, controller}`, where `cdp` is `"relay"` while the browser runs (`null` when stopped) and `controller` is `user`, `agent` or `none`.

**Routes.** Device token only (`Authorization: Bearer`; a request with `Origin` gets 403), as for the file routes. `?workspace=<name>` is optional (default `shared`) and checked like the `browser.*` methods (400 when bad). The checks run before the upgrade.

- `GET /v1/browser/tabs` answers `200` with `[{"id", "type": "page", "title", "url"}]`: the pages of the browser, as DevTools' `/json/list` lists them.
- `GET /v1/browser/cdp` (WebSocket): the browser level. Commands carry no `sessionId`; the socket gets browser-level events.
- `GET /v1/browser/cdp/page/{target_id}` (WebSocket): one tab, as a plain CDP session. `target_id` is 1 to 64 ASCII letters or digits, else 400. No such tab: 404 `{"error": "no_such_tab"}`.
- No browser running: 409 `{"error": "browser_not_running"}` (the tabs route too). A device may hold 16 of these sockets at once; the 17th gets 429.
- A WebSocket carries one CDP message per text frame, in each direction. Binary frames are ignored.

`browser.control{workspace?, holder}` sets who drives it. `browser.stop` stops it, and `browser.touch` only counts as activity.

Chrome has no DevTools port any more, so `/v1/tunnel` cannot reach the browser. The old `browser.status` fields `cdp_port` and `browser_ws_path` are gone.

**Idle stop.** A browser with no agent call, no `browser.status` or `browser.touch`, and no opened `/v1/browser/*` socket for 30 minutes is stopped; the check runs every minute. An open socket alone does not count, so the app calls `browser.touch` while it shows the browser.

**Errors.** `BROWSER_ERROR` (-32026), with `error.data.reason`: `missing_component`, `start_failed`, `unsupported` (not Linux or macOS), `not_running`, `user_controls`, `declined`, `failed`. A bad workspace name (letters, digits, `-`, `_`, up to 64) or a URL that is not `http`, `https`, `data:` or `about:blank` is `-32602`.

**Agent tools.** The crew MCP server offers the browser tools, and each one calls `browser.agent.*` on the unix socket. Those methods accept only agents, on `agent.sock`, for their own agent. The browser starts on the first use. While `controller` is `user`, every tool call fails with "The user is using the browser. Wait or ask them to hand it back.". Refs come from the latest snapshot and are the DOM node's `backendDOMNodeId`.
- `browser_snapshot` returns the title, the URL, and one line per link, button, textbox, searchbox, combobox, checkbox, radio, menuitem, tab, heading, or named image: `[ref] role "name" (value)`. Names are cut at 120 characters; there are at most 600 element lines.
- `browser_open{url, new_tab?}` navigates the agent's tab, or opens a new one, and waits for the load event for up to 30 s.
- `browser_click{ref}`, `browser_type{ref, text, submit?}`, `browser_press{key}` (named keys only, such as `Enter`, `Tab`, `Escape`, `ArrowDown`), `browser_back`, `browser_screenshot` (PNG, at most 1280 px wide, returned as an image), `browser_tabs` (`*` marks the agent's tab), `browser_switch{index}`.

**Risky clicks.** `browser.agent.click{agent_id, ref}` reads the element's role, name and value first. If the name or the value contains one of the words below (case-insensitive substring match), the daemon asks the human before it clicks. It does this itself, not through the runtime, so every runtime behaves the same. The request is an approval in the agent's feed: tool `browser_click`, title `Нажать «<the element's real name>» на <host>`, the page URL as command, reason `browser: risky click`. The user answers it in the app with `approvals.resolve`, as with any approval. Allow: the click happens. Deny, or no answer within 10 minutes: the agent gets "The user declined this click.", and the click does not happen. Ordinary clicks and typing are not asked about. Words: `pay`, `buy`, `purchase`, `checkout`, `order`, `subscribe`, `send`, `submit`, `delete`, `remove`, `transfer`, `confirm`, `оплат`, `куп`, `заказ`, `подпис`, `отправ`, `удал`, `перев`, `подтверд`.

**Orphans.** When the daemon starts, it stops Chrome processes an earlier daemon left behind: processes whose command line has this server's `workspaces/` folder in `--user-data-dir`. On Linux it reads `/proc`; on macOS it uses `pgrep -f`. Other Chrome processes, such as the user's own, are not touched.

**Profile.** The profile keeps the browser's sign-ins to websites. Agents and the app share it, and it stays on the server, with the same owner as the daemon. Deleting `workspaces/<workspace>` signs out everywhere.

## Preview proxy

**App side.** A preview web view serves one port: the one it was opened for. A `bandito-preview://p<other port>/` load gets 404. The web view's requests go through the daemon's request builder with the device token, so the token never reaches the web view, and it is sent only where a token may go (TLS or loopback). The request carries the method, `Content-Type` and other headers and the body, but not `Authorization`, `Cookie`, `Host` or hop-by-hop headers; it asks for `Accept-Encoding: identity`. The response goes back without `Content-Encoding` and `Content-Length`. Each preview has its own session with no cache and its own cookies; the daemon's tab list has no cache either.

`GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE` and `OPTIONS` on `/v1/proxy/<port>/<path>` forward to `127.0.0.1:<port>` on the server, so the app can show a dev server an agent started. Access is the same as for the file routes: a paired device (`Authorization: Bearer`), and no browser `Origin` (403). A port outside 1..=65535 is 400. Code: `daemon/src/rpc/preview.rs`; the route is in `rpc/ws.rs`.

- Request: the hop-by-hop headers (`Connection` and the names it lists, `Keep-Alive`, `Proxy-*`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`) are not passed on. Neither are `Authorization` (the device token) and `Host`; the target gets `Host: 127.0.0.1:<port>`. The body is streamed.
- Response: status, headers (without hop-by-hop ones) and body are streamed back. A `Location` of `http://127.0.0.1:<port>` or `http://localhost:<port>`, or a root path (`/x`), is rewritten under the proxy prefix (`/v1/proxy/<port>/x`), so a redirect stays in the preview.
- Connecting to the target takes at most 5 s; otherwise 502.
- WebSocket upgrades are refused with 501. Root-relative links inside HTML and JavaScript are not rewritten, so a page that uses them shows, but its links to `/x` go to the server root.

## Terminals

Persistent shells and programs on the server, PTY-backed, like a tmux-lite. A terminal keeps running while no app is attached. Unix only. `daemon/src/terminal.rs` is the engine; `daemon/src/rpc/term.rs` is the RPC layer.

A terminal runs as the daemon's user, so a paired app can do anything that user can. Anonymous connections get `UNAUTHORIZED`.

Methods:

- `term.list {}` → `[TermInfo]`, oldest first.
- `term.open {cwd?, command?: [string], title?, cols, rows, env?: {string:string}}` → `TermInfo`. `cwd` defaults to the home folder; `~` and `~/…` expand; anything else must be an absolute, existing folder (else `INVALID_PARAMS`). `command` defaults to the user's login shell. `cols` and `rows` are 1..=1000.
- `term.input {id, data}` → `{}`. `data` is base64, at most 64 KiB decoded.
- `term.resize {id, cols, rows}` → `TermInfo`; `term.rename {id, title}` → `TermInfo`.
- `term.close {id}` → `{}`. Hangs up the process group: SIGHUP, then SIGKILL after 2 s.
- `term.attach {id, from?}` → `{info, start, data}`. Subscribes this connection to the terminal's output. `data` is base64 output from `start` to the current offset; `start` is `from` (or the oldest byte still kept, if `from` is older). Attaching again only resets the connection's expected offset.
- `term.detach {id}` → `{}`. The terminal keeps running; its output goes on into the scrollback.

Notifications, sent on the connection that attached (every one has `id`):

| method | params | meaning |
|---|---|---|
| `term.output` | `{id, offset, data}` | base64 bytes that start at byte `offset` of the terminal's output |
| `term.gap` | `{id, lost}` | `lost` bytes were not delivered (scrollback overflow, or the connection lagged); sent just before the output that follows |
| `term.exit` | `{id, code, signal}` | the program ended; `code` or `signal` is null |
| `term.closed` | `{id}` | the terminal was closed; the connection is no longer attached to it |

Offsets: each terminal counts its output bytes from 0 and never resets. A client remembers the offset just past the last byte it has; `term.attach {from}` continues from there. A connection that goes away detaches from all its terminals, which keeps running. An app that collapses a terminal keeps its stream attached: the pane leaves the screen, but the app still reads the output (line counts, the dock's sparkline, the waiting-for-input prompt) and keeps the emulator state in memory. It sends `term.detach` only when it stops following the terminal: on quitting, on removing the server, or after a close. A detached terminal is shown again with `term.attach` from the stored offset.

Limits: 16 live terminals (an exited one keeps its slot until closed); 512 KiB of output history per terminal; 64 KiB per `term.input`. An input that cannot be written within 5 s fails with `busy`, and a prefix of it may already have been written.

Environment: a terminal gets only a whitelist of the daemon's variables (`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `SHELL`, `TZ`, `TMPDIR`, `XDG_RUNTIME_DIR`) plus the `env` given to `term.open`. The daemon's secrets (API keys, tokens) never reach a terminal. It also sets `BANDITO_TERM=1` and `BANDITO_TERM_ID=<terminal id>`, which mark the terminal's processes for [Host](#host).

Errors: code `-32021` (`TERM_ERROR`), message `<code>: <text>`, where `<code>` is `too_many`, `not_found`, `invalid_size`, `exited` or `busy`.

When the daemon stops, every terminal is hung up (`TerminalManager::shutdown_all`). Feature string: `"terminals"` in `daemon.info`.
## Secrets

API keys and passwords that agents need, such as `OPENAI_API_KEY` or a database password. A session gets them as environment variables when it starts. Their values never reach the app, the event log or the chat. `daemon/src/store/secrets.rs` holds the rules and storage, `daemon/src/redact.rs` the redaction, `daemon/src/rpc/secrets.rs` the methods. Clients show the feature when `daemon.info.features` contains `"secrets"`.

- `secrets.list {}` → `[SecretInfo]`, sorted by name.
- `secrets.set {name, value, agents}` → `SecretInfo`. Creates the secret or replaces its value and agents.
- `secrets.delete {name}` → `{deleted: bool}`.

`SecretInfo` is `{name, tail, agents, updated_at}`. `tail` is the last 4 characters of a value of 12 characters or more, otherwise `""`. No method returns a value. `agents` lists agent ids; `["*"]` means every agent, and `[]` means no agent yet. A list that mixes `"*"` with ids is `INVALID_PARAMS`.

**Rules.** Name: `^[A-Z_][A-Z0-9_]{0,63}$`, and not `PATH`, `HOME`, `USER`, `SHELL`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, or anything starting with `DYLD_` or `BANDITO_`. Value: 1 to 65 536 bytes, no NUL byte. Bad input is `INVALID_PARAMS`, and nothing is stored.

**Storage.** Table `secrets` in `bandito.db`, as plain text. The daemon sets the database file to mode 0600 when it opens it (unix). Values are not encrypted. The server's owner can read the file, and so can an agent with shell access, because it runs as the same user. This is the owner model; encryption at rest (keychain, age) comes later.

**Delivery.** A session gets the secrets that list its agent id, or `*`, as environment variables of the CLI process. `secrets.set` and `secrets.delete` restart the sessions of the agents concerned (every agent for `*`): an idle session closes at once, a running one when its turn ends. The next message starts with the new values. Terminals never get them (see Terminals).

**Redaction.** Before an event is stored or sent, each value of the session's secrets is replaced by `••••NAME`. This covers message text, tool call titles and inputs (every string inside the JSON), tool output, error text, and approval title, command, diff, input and reason. The approval keeps its key, so the answer still reaches the right request. Messages the user types are stored as typed. Values shorter than 6 bytes are not redacted. Where values overlap, the longer one wins.

**Limits.**

- Redaction works on whole strings. A value split across two `message.delta` chunks can show in the live stream. The stored `message.assistant` text is complete and redacted.
- Runtimes cut tool output to 16 KB before the daemon sees it, so a value cut at that point leaks its first part. Encoded forms of a value (base64, URL-encoded) are not matched.
- Redaction protects the chat, the event log and the app. It does not protect files. An agent that writes a secret into a file it may write has put it on disk, where it is the owner's to keep.

## Files

The app browses and edits files on the server: `fs.*` RPC methods, plus `GET`/`HEAD /v1/files/raw` to stream a file's bytes. Clients show the feature when `daemon.info.features` contains `"files"`.

**Access.** Any paired device can use the file methods and the raw endpoint, with the rights of the user running the daemon. The model is owner-of-the-server: roots are a convenience limit, not a security boundary. `~` is the daemon user's home; other paths must be absolute. A relative path is `invalid_path`.

Params are objects; unknown fields are `invalid_params`.

| method | params | result |
|---|---|---|
| `fs.list` | `path`, `hidden?` (default false) | `Listing {path, parent, entries, truncated, skipped}` |
| `fs.stat` | `path` | `Entry` |
| `fs.read` | `path` | `TextFile {path, content, etag, size, modified_ms, readonly}`; text up to 2 MiB, binary refused |
| `fs.write` | `path`, `content`, `etag?`, `create?` (default false) | `{etag}` |
| `fs.create_file`, `fs.mkdir` | `path` | `Entry` |
| `fs.rename`, `fs.copy` | `from`, `to` | `Entry` |
| `fs.trash` | `path` | `{trashed_to}` |
| `fs.search` | `root`, `query`, `limit?` (1–1000, default 200) | `[Entry]` |
| `fs.projects` | `limit?` (1–200, default 30) | `[ProjectHint]` |
| `fs.upload.begin` | `path` (destination) | `{upload_id}` |
| `fs.upload.append` | `upload_id`, `offset`, `data` (standard base64) | `{written}` |
| `fs.upload.commit` | `upload_id`, `overwrite?` (default false) | `Entry` |
| `fs.upload.abort` | `upload_id` | `{}` |
| `fs.clone` | `url`, `dest` | `{path, default_branch}` (see below) |

**Writing.** Overwriting an existing file needs the `etag` from the last `fs.read`. Without it, or with a stale one, the write is refused with `conflict`, and `error.data.etag` holds the current etag. `create: true` without an etag makes a new file and gives `exists` if the path is taken. `etag` on a missing file gives `not_found`.

**Errors.** File failures use code `-32020` and `error.data.reason`: `not_found`, `exists`, `not_a_directory`, `is_a_directory`, `not_a_file`, `permission_denied`, `too_large` (`size`, `limit`), `binary`, `conflict` (`etag`), `invalid_path`, `outside_roots`, `cross_device`, `io`, `clone_failed` (`stderr`). Bad params are `-32602`.

**Clone.** `fs.clone` copies a git repository into a new folder. `url` is `https://…` or scp-style `user@host:path` (ssh); anything else (`file://`, `http://`, `ssh://`, options such as `--upload-pack=…`) is `invalid_params`. `dest` is resolved like any path (`~` is home, otherwise absolute, under the roots) and must not exist, though its parent must. The daemon runs `git clone --depth 50 -- <url> <dest>` with a 10-minute limit and `GIT_TERMINAL_PROMPT=0`: nothing prompts, and private repositories work through the server's own ssh keys. The result is `{path, default_branch}` (`default_branch` is `null` when HEAD is detached). A failure is `FS_ERROR` with `reason: "clone_failed"` and `data.stderr`: the last 2 KB of git's stderr, with `user:password@` cut from every URL in it. The partial folder is removed. An existing `dest` gives `exists`.


**Upload in chunks.** `begin` creates a temp file next to the destination. Each `append` must send `offset` equal to the bytes already written; a chunk is at most 1 MiB decoded, and the total at most 4 GiB. One WebSocket message may be up to 4 MiB, so a full 1 MiB chunk fits after base64. `commit` moves the file into place (`overwrite: false` gives `exists`). An upload idle for an hour is removed with its temp file (checked every 10 minutes). `abort` removes it at once.

**Raw download.** `GET` or `HEAD /v1/files/raw?path=<percent-encoded>` (encode `+` as `%2B`; the query is form-decoded). Needs `Authorization: Bearer`: no token or an unknown one is 401, and an `Origin` header is 403. Errors: 400 for an invalid path, a folder or a non-regular file; 403 outside roots or no permission; 404 when missing. The body is streamed from the file.

- `Range`: one `bytes=a-b`, `bytes=a-` or `bytes=-n` gives 206 with `Content-Range`. A range outside the file, a reversed range, or several ranges gives 416 with `Content-Range: bytes */size`.
- `Content-Type` by extension: video, audio, image and PDF types as usual; text, markdown, code and config files as `text/plain; charset=utf-8`; SVG and HTML are never served as markup; anything else is `application/octet-stream`.
- Always: `ETag: "<size>-<mtime_ms>"`, `Accept-Ranges: bytes`, `Cache-Control: private, no-cache`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: sandbox`, `Content-Disposition: inline; filename*=UTF-8''<name>`.

## Tunnel

`GET /v1/tunnel?port=<1..=65535>` is a WebSocket that carries one TCP connection to `127.0.0.1:<port>` on the server. It lets the app reach what agents start on the server, such as a dev server on `localhost:3000`. Later it carries the server's screen (VNC). A browser's DevTools protocol does not go through it: see [Browser](#browser). The client listens on a local port of its own and sends the traffic through this socket: a WKWebView points at the local port, a VNC viewer connects to it.

**Access.** Same as the file routes: a paired device only. Without `Authorization: Bearer` the upgrade is 401, and so is an unknown or revoked token. An `Origin` header is 403. Checks run before the upgrade, so a refusal is a plain HTTP response.

**Target.** The loopback interface only. The only parameter is `port`: no host, no path, so the route cannot reach other machines (no SSRF). The daemon tries `127.0.0.1:<port>`, then `[::1]:<port>`, with 5 s to connect. If neither accepts, the socket closes with code 1011 and reason `connect failed`. A missing `port`, or one outside 1..=65535, is 400 before the upgrade.

**Frames.** The tunnel is a byte stream. Binary WebSocket messages go to the target as they are, and the target's bytes come back in binary messages of up to 64 KiB, so one message does not map to one TCP read. A text message from the client is ignored. A message over 1 MiB closes the tunnel. Ping and pong work as in axum by default.

**Close.** When either side closes or fails, the daemon shuts down the TCP write side and closes the WebSocket with code 1000. The target closing ends the WebSocket the same way.

**Limits.** At most 64 live tunnels per device. The 65th upgrade gets 429 before the upgrade. A slot is freed when its tunnel ends, whichever side ended it.

Feature string: `"tunnel"` in `daemon.info`.

**Known limits (accepted, not fixed).** A forwarder (`forwardOnce`) accepts exactly one connection on its loopback port, and until that connection arrives any local process can connect to the port first (one-shot listener). The daemon's pipes to Chrome are made close-on-exec as `std::io::pipe` does it on macOS, which sets the flag after the descriptor exists, so a fork on another thread in that instant could hand a pipe to a child that is not Chrome.

## Changes

Bandito records what an agent changes in its folder, so the app can show it and undo it. The working folder does not need to be a git repository.

**Checkpoints.** Before a turn that starts from a user, schedule or crew message, the daemon takes a snapshot of the agent's working folder (its `cwd`): a `before` checkpoint, labelled with the start of the message. When the turn ends, an `after` checkpoint is taken in the background. Wrap-up turns (saving memory) are not checkpointed. A snapshot is a commit in a shadow git repository, `.checkpoints/` inside the agent's home folder, driven with `GIT_DIR` and `GIT_WORK_TREE` set to the working folder. A project's own `.git` is never touched, and its `.gitignore` is honored. An unchanged folder gives the same commit, so a turn that changed nothing adds no new commit.

Not checkpointed: credentials (`.env`, `.env.*`, keys, certificates, `.npmrc`, `.netrc`), files over 5 MiB (they are dropped from the index and stay out), `node_modules/`, `target/`, `.venv/`, `venv/`, `__pycache__/`, `dist/`, `build/`, `.next/`, `.cache/` and `*.log` (the full list is in `daemon/src/checkpoint.rs`), and whole folders with more than 20 000 files. A `before` snapshot that takes more than 10 s is abandoned, and the turn goes on without it. The shadow repository holds file contents, including files that the project ignores in git but this list does not exclude (such as `.env`). It sits in the agent's home folder, which only the daemon's user can read.

**Restore.** A restore first takes a `restore` checkpoint of the current state, so it can be undone with the same method. Paths must be relative and stay inside the working folder; `.git` and `.checkpoints` are refused. Without `paths`, every file that differs from the checkpoint comes back, and files that did not exist then are removed.

**Methods.**

| method | params | result |
|---|---|---|
| `changes.checkpoints` | `agent_id`, `limit?` (1–200, default 50) | `[{id, sha, label, kind, turn_id, created_at}]`, newest first |
| `changes.diff` | `agent_id`, `from?`, `to?` (checkpoint ids) | `{from, to, files}` |
| `changes.file` | `agent_id`, `path`, `from?`, `to?` | `{diff, truncated}` |
| `changes.restore` | `agent_id`, `checkpoint_id`, `paths?` | `{restored, undo_checkpoint_id}` |

`from` defaults to the agent's last `before` checkpoint, `to` to the working folder as it is now (`to` is then `null`). A `file` is `{path, status, from?, additions, deletions}` with `status` one of `added`, `modified`, `deleted`, `renamed` (`from` is the old path of a rename). `additions` and `deletions` are `null` for binary files. `changes.file` gives a unified diff with 3 lines of context, cut at 512 KiB (`truncated: true`).

**Errors.** An unknown agent, a checkpoint of another agent, a bad path or a bad id is `INVALID_PARAMS`. A git or file failure is `CHANGES_ERROR` (`-32022`) with `error.data.reason`: `missing_folder`, `too_many_files`, `undo_unavailable`, `git` or `io`. An agent with no checkpoints gets empty lists, not an error.

Feature string: `"changes"`.

## Host

The app shows what the server is doing: CPU, memory, disks, network, the processes of each agent and terminal, and the ports they listen on. Clients show it when `daemon.info.features` contains `"host"`. Code: `daemon/src/host.rs` (readers and sampler), `daemon/src/rpc/host.rs` (methods).

**Methods.** Error code `HOST_ERROR` = `-32023`; `error.data.reason` is `forbidden`, `not_found` or `io`. A bad `pid` or `range` is `-32602`.

| method | params | result |
|---|---|---|
| `host.stats` | `{}` | `HostStats`: the last sample, or a fresh one if the daemon has not sampled yet |
| `host.history` | `range`: `"1h"` or `"24h"` | `{points: [{t, cpu, mem_used, net_rx_bps, net_tx_bps}]}`, at most 360 points, each the average of its span; `t` is Unix ms |
| `host.processes` | `{}` | `{supported, owners: [{owner, cpu_percent, rss_bytes, processes: [{pid, name, cmd}]}]}` |
| `host.ports` | `{}` | `{supported, ports: [{port, addr, pid, process, owner?}]}`, unique by port and address |
| `host.kill` | `pid` | `{}` |
| `host.kill_process` | `pid` | `{ok: true, killed}`: only a process of the daemon's user whose tree can be read and that belongs to no agent, terminal or the daemon (refused: `forbidden`, the reason says which); SIGTERM now, `killed` says whether it was gone within 1 s (a zombie counts as gone); SIGKILL after 5 s if it is still the same process (same start time). Paired devices may call it: they are the owner's own. |

`HostStats` fields: `os`, `kernel`, `arch`, `hostname`, `cpus`, `cpu_percent` (busy share of all CPUs), `load` (1, 5, 15 min), `mem_total`, `mem_used`, `swap_total`, `swap_used`, `disks: [{mount, total, used}]` (`/` and the daemon user's home, one entry per device), `net_rx_bps`, `net_tx_bps`, `net_supported`, `uptime_s`, `top_processes`. Bytes everywhere unless a name says `_bps`.

`top_processes`: the union of the 15 biggest processes of the whole server by memory and the 15 busiest by CPU, without repeats, biggest memory first. Each entry is `{pid, name, rss_bytes, cpu_percent, own, own_safe}`. `name` is the program's file name; `own` says the process runs as the daemon's user; `own_safe` says the app may stop it (see `host.kill_process`). It is read when `host.stats` answers, not in the 10 s sample. The first CPU reading after the daemon starts is 0.

**Stopping a process.** `host.kill_process` reads the process's start time first, reads the process table and the owner marks, and refuses unless the tree is known and the process has no owner. It reads the start time again just before SIGTERM: a pid that another process took meanwhile has another start time and is refused. The window that stays open is between that second reading and `kill(2)`: a few microseconds in which the process must exit and its pid be reused. macOS has no pidfd to close it, and Linux is not given one here. SIGKILL after the grace period checks the start time again, so a reused pid is left alone.

**Sampling.** The daemon samples every 10 s and keeps the last 24 h (8640 samples) in memory. The history is lost on restart.

**Sources.** Linux: `/proc/stat`, `loadavg`, `meminfo` (used = total − available), `net/dev` (loopback excluded), `uptime`, `sys/kernel/osrelease`, `/etc/os-release` (`PRETTY_NAME`), `statvfs`. macOS: `sysctl` (`hw.ncpu`, `hw.memsize`, `kern.boottime`, `kern.osrelease`, `kern.osproductversion`, `vm.loadavg`), `vm_stat` (used = active + wired + compressed pages), `netstat -ib`, `ps`, `lsof`, `statvfs`.

**Owners.** A process belongs to the owner of its nearest ancestor (or itself) that is a root: an agent's CLI, or a terminal's shell, registered by the daemon when it starts them. The environment mark (`BANDITO_AGENT_ID=<agent id>` for an agent CLI, `BANDITO_TERM_ID=<terminal id>` for a terminal) is a second sign, read where `ps` or `/proc` shows it. The tree is needed on macOS: Apple's own programs (`zsh`, `sleep`) hide their environment from `ps`, so their children are owned through their parents. A test run or a dev server started by an agent is listed under that agent. The daemon's own process is `{kind: "daemon", id: null}`; its children belong to nobody. Other processes are not listed. An owner's `cpu_percent` is summed over its processes, so it can exceed 100.

**Fail-closed.** A process whose tree cannot be read to the end (a parent missing from the process table) has no owner it can be shown under, and is never stopped from the app. The same goes for a process that the process table cannot be read for at all.

**CPU per process.** Both platforms: the share of one core between two readings, from the change in the process's CPU time (Linux utime + stime, macOS the `time` column of `ps`, to the hundredth of a second). The first reading reports 0. Readings closer together than one second keep the previous shares, so a second `host.*` call right after another does not show noise.

**Ports.** Owners come from the same tree as the processes. Linux: `/proc/net/tcp` and `tcp6`, state LISTEN. The socket's owner is found through `/proc/<pid>/fd`, so a port of another user's process has `pid: null`. IPv4-mapped IPv6 addresses print as IPv4. macOS: `lsof -nP -iTCP -sTCP:LISTEN`; `addr` `*` means all interfaces.

**Kill.** `host.kill` sends SIGTERM to a process that belongs to an agent or a terminal. The daemon itself, processes without an owner (init, other users) and `pid` ≤ 0 are refused with `reason: "forbidden"` (or `-32602` for `pid` ≤ 0, since `kill(0)` and `kill(-1)` would signal whole groups). After 3 s SIGKILL follows if the process is still there with the same owner.

**Limits on macOS.** `ps -E` shows the environment only of processes of the same user that are not Apple system binaries. So agent CLIs (node, Rust, Python) and what they start count, while short system tools (`/bin/sleep`, `/bin/sh`, `/bin/zsh`) have no owner. Swap is not read (0). Without `netstat` the network fields are 0 and `net_supported` is `false`. `supported: false` in a process or port reply means the platform has no reader (not Linux or macOS, or `ps`/`lsof` missing).

## Install and service

`scripts/install.sh` (served as `https://bandito.dev/install.sh`) picks the release asset for the machine (`bandito-<target>.tar.gz`, targets `x86_64|aarch64` × `unknown-linux-gnu|apple-darwin`), checks it, installs `bandito` to `~/.local/bin`, and runs `bandito service install` unless `--no-service` is given. Releases are built by `.github/workflows/release.yml` on tag publish or by manual dispatch with a tag.

Release signing: the last job of the release workflow lists the SHA-256 of every archive and of `install.sh` in `SHA256SUMS` and signs that file with the release key (Ed25519, raw signature, base64 in `SHA256SUMS.sig`). The private key is the repository secret `RELEASE_SIGNING_KEY`; `scripts/release-key.sh` makes it on the owner's Mac, stores it there and in a keychain backup, and writes the public key into `install.sh` (`RELEASE_PUBKEY`). `install.sh` verifies the signature with OpenSSL 3 and takes the archive's hash from the signed list. Without OpenSSL 3 it falls back to the per-archive `.sha256` with a warning, unless `BANDITO_REQUIRE_SIGNATURE=1`. The Mac app does not depend on the server's OpenSSL: it downloads the archive and `SHA256SUMS` on the Mac, verifies the signature with CryptoKit against the key it carries, copies the archive, `SHA256SUMS` and `SHA256SUMS.sig` over SSH to `~/.cache/bandito-install/` and runs `install.sh --archive FILE --sums FILE --sig FILE` with `BANDITO_REQUIRE_SIGNATURE=1`; the three files are removed afterwards. On the server the script compares the archive's SHA-256 with its line in `SHA256SUMS` on every machine, without OpenSSL, and checks the signature of `SHA256SUMS` when OpenSSL 3 is there. Without OpenSSL 3 the server cannot check the signature, so the Mac's check is the only one: the script warns and installs, because the app has verified the same files. The hash check still refuses a file swapped in transit. A release that does not exist yet for the app's version falls back to the latest one, with a line in the install log; a latest older than the app is refused as still being published.

`bandito service install` writes `~/.config/systemd/user/bandito.service` (Linux) or `~/Library/LaunchAgents/dev.bandito.daemon.plist` (macOS), starts it, and waits up to 10 s for `daemon.info` on the socket. Linux machines without a user systemd manager (WSL without systemd, containers) get a detached background process with its pid in `<home>/daemon.pid` and output in `<home>/logs/daemon.log`; it does not survive a reboot. On Linux the installer also asks for lingering (`loginctl enable-linger`), so the daemon outlives the SSH session that installed it; if that is refused, the command prints the `sudo` line. `service uninstall` removes the unit or plist and stops the daemon; data is kept. `service install --dry-run` prints what would be written and run, and changes nothing.

Machine-readable output for scripts and the app: `bandito pair --json` prints `{"code","expires_in_ms"}`; `bandito info --json` prints version, paths, `listen`, `running`, and the `features` the daemon reports (empty when it is down); `service install --json` prints `{"ok","mode","listen","socket","warnings"}`; `service status --json` prints `{"installed","mode","running","pid"?}`.

## Self-update

`bandito update [--check] [--json] [--version vX.Y.Z] [--allow-downgrade]` installs a newer release. Over RPC, `daemon.update_check` → `UpdateInfo {current, latest, available}` and `daemon.update_apply {version}` → `{ok, restarting}` do the same. Both are for the owner (`bandito.sock`) and for paired apps (a device is the owner's app, so it may apply too); agents and anonymous peers are refused by `allowed()`. Feature `update`. Code: `daemon/src/update.rs`. Nothing installs by itself: only the owner asks.

**Newest release.** A `curl -I` (a HEAD request, https only, TLS 1.2 or newer, redirects only to https) of `https://github.com/banditohq/bandito/releases/latest` ends at `releases/tag/vX.Y.Z`; the tag is the version. Only `MAJOR.MINOR.PATCH` is accepted. A repository without a published release answers 404, which is reported as `no releases published yet`; other failures are `cannot reach GitHub`. A successful check is reused for 10 minutes, and concurrent checks share one lookup. A downgrade is refused unless `--allow-downgrade` is given (CLI only); installing the running version is refused.

**Install.** Only one update runs at a time: `apply` takes an exclusive `flock` on `<data dir>/run/update.lock`, shared by the RPC and the CLI, and a second one fails with `busy`. In `<data dir>/run/update-<id>` (mode 0700, removed afterwards) the daemon downloads `SHA256SUMS`, `SHA256SUMS.sig` and `bandito-<target>.tar.gz`, targets as in `scripts/install.sh`. Sizes are limited: the archive to 200 MiB, the sums and the signature to 64 KiB (`--max-filesize`, and the size on disk is checked again). Checks, in this order, and nothing is replaced before all of them pass:
1. Ed25519 `verify_strict` of the exact bytes of `SHA256SUMS` with the release key (`RELEASE_PUBKEY_B64` in `daemon/src/update.rs`, the same key as `RELEASE_PUBKEY` in `install.sh`; a test keeps them equal). Failure: `signature check failed`. The archive is not downloaded before this passes.
2. The archive is listed in `SHA256SUMS` (`<hash>  <name>` or `<hash> *<name>`). Failure: `asset not listed`.
3. The archive's SHA-256 equals its line. Failure: `checksum mismatch`.
4. Only the member `bandito` is extracted (`tar --no-same-owner`), and its entry must be a regular file, not a link (`symlink_metadata`). Failure: `archive entry is not a regular file`. Only then is it made executable and run.
5. Its `--version` prints `bandito <version>`. Failure: `version mismatch`.

The binary is then copied next to the running one as `.bandito.new.<pid>`, chmod 755, and renamed over it: a running daemon keeps its old inode.

**Restart.** The pid comes from the daemon itself: the daemon that answers on the socket reports its own `pid` in `daemon.info`, and that is the pid signalled. The service files give how it runs, and the service manager must name the same pid: systemd `MainPID`, launchd `PID`, or, for a background process, its pid file. A stale pid file, another process, or no answer on the socket means no restart; the reply then says so. systemd: `systemctl --user --no-block restart bandito.service`. launchd: `launchctl kickstart -k gui/<uid>/dev.bandito.daemon`. Background process: a shell waits (up to 30 s) for the old pid to exit, then starts the new daemon with the same arguments in its own process group, and the old one gets SIGTERM. Over RPC the restart runs one second after the reply, so the app gets it. Any other process (`bandito daemon` by hand) is not restarted: the binary is replaced and the reply says `restarting: false`.

**Background check.** The daemon checks for a newer release 10 minutes after start and then every 24 hours (`update::spawn_background_check`). A newer release is written to the log. Nothing is installed. `daemon.info` carries the last successful check as `update: {current, latest, available, checked_at}` (`null` until one succeeds), and the app shows its button from it.

**Mac app.** Server → Overview shows the daemon's offer as a card, and the server menu shows a dot. The button asks `daemon.update_apply` after a confirmation, then waits for `daemon.info` to report the new version. See [Mac app updates](#mac-app-updates).

**Not in place: revocation and a minimum version.** The client has no revocation list and no minimum version. A release that the release key signed installs when the owner asks, even if it was later withdrawn from GitHub. The protection is the signature, the download limits and the owner's choice; a compromised release key would need a new key in the apps and in `install.sh`.

## Setup

The server sets itself up from the app. The daemon knows which components each feature needs, checks whether they are there, and installs the missing ones. Clients show a feature from `setup.status`, and offer the install. Code: `daemon/src/setup.rs` (checks, plans, jobs), `daemon/src/rpc/setup.rs` (methods). Feature string: `"setup"`.

**Features and components.** `screen` needs `xvfb`, `x11vnc`, `xdotool`, `xauth`, `imagemagick` (`import`), `window_manager` (openbox) and `fonts` (Noto). `browser` needs `browser` and `fonts`. `agents` are `claude`, `codex` and `grok`; `claude` and `codex` need `node`. `containers` needs `docker`. The screen feature is `unsupported` off Linux.

**Checks.** A component is installed when its program is on `PATH`: `Xvfb`, `x11vnc`, `xdotool`, `xauth`, `import`, `openbox`, one of `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser`, or `node`, `claude`, `codex`, `grok`. Tools that have a version must answer `--version`. Node must be 18 or newer (`node --version`). `fonts` passes when `fc-list` lists a Noto family. `docker` passes when `docker info` succeeds. The check uses the daemon's `PATH`, which starts with `<data dir>/tools/bin`.

**How it is installed.**

| component | how | needs sudo |
|---|---|---|
| `xvfb`, `x11vnc`, `xdotool`, `xauth`, `imagemagick`, `window_manager`, `fonts`, `browser` | apt, dnf or pacman, one batch per job (apt runs `update` first). Ubuntu on x86_64 gets Google Chrome from Google's signed apt repository, since its `chromium-browser` is a snap (see below). Ubuntu on arm64 has no installer | yes |
| `node` | Node 22 LTS tarball from nodejs.org, checked against `SHASUMS256.txt` (sha256), unpacked into `<data dir>/tools/node`, linked as `node`, `npm`, `npx` in `<data dir>/tools/bin` | no |
| `claude`, `codex` | `npm install -g @anthropic-ai/claude-code@2.1.295` / `@openai/codex@0.162.0` with `NPM_CONFIG_PREFIX=<data dir>/tools`. The versions are pinned in `NPM_PINS` (`daemon/src/setup.rs`) and move only with a Bandito release | no |
| `grok`, `docker` | not installed by Bandito. The hint names the docs; a docker permission error hints `sudo usermod -aG docker $USER` | — |

**Google Chrome on Ubuntu (x86_64).** Chrome comes from Google's apt repository, signed. The job downloads `https://dl.google.com/linux/linux_signing_key.pub` (https only, TLS 1.2 or newer) into `<data dir>/tools/downloads`, and `gpg --dearmor` turns it into a keyring there. That keyring is checked before anything is installed: `gpg --show-keys --with-colons` must list exactly one primary key, and the `fpr:` line right after its `pub:` line must be `EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796`, the primary key of Google's Linux Package Signing Authority. Subkeys do not count, and a keyring with a second key in it is refused. Otherwise the job fails with `Google signing key fingerprint mismatch`, deletes the files, and runs nothing more. The checked keyring is then installed with `sudo -n install` as `/etc/apt/keyrings/google-chrome.gpg`, with the sources line `deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main` in `/etc/apt/sources.list.d/google-chrome.list`. apt then updates from the Chrome list alone, and installs `google-chrome-stable`. A keyring and list already in place, passing the same check, are not written again. gpg is installed with the package batch when it is missing.

On macOS, Bandito installs only `node`, `claude` and `codex`. The screen feature is `unsupported`, and `browser`, `grok` and `docker` show a hint.

**Sudo.** Bandito never asks for or takes a sudo password. Package commands run as `sudo -n`, which fails rather than prompt. `setup.status` reports `sudo`: `passwordless` (`sudo -n true` works), `password` (sudo exists but asks), or `none` (no sudo). When a job needs sudo and it is not `passwordless`, nothing runs: the job ends in `needs_password` with `command`, the exact command line for the user to run in a terminal of the app. The app opens that terminal; the user types the password there, not in Bandito. Then the user starts the install again. Commands for node and the agent CLIs never use sudo.

**Jobs.** `setup.install` starts one job in the background and answers at once. A second install while one runs is `busy`. The order is node, then system packages (one batch), then Chrome, then npm packages. A component that needs node pulls it in. No command gets stdin. apt installs run with `DEBIAN_FRONTEND=noninteractive`, and each command has a limit of 15 minutes. Its stdout and stderr go to the job log. At the end every requested component is checked again. A failure names the first component still missing in `failed_component`.

**Methods.**

| method | params | result |
|---|---|---|
| `setup.status` | `{}` | `{os, arch, package_manager, sudo, components: [Component], features}`. `Component` is `{id, feature, installed, version, installable, needs_sudo, hint}`. `features` is `{screen, browser, containers: ready\|missing\|unsupported, agents: {claude, codex, grok: ready\|missing}}` |
| `setup.install` | `{components: [id]}` | `{job_id}`. Unknown ids and an empty list are `-32602` |
| `setup.job` | `{job_id, from?: u64}` | `{state, step, log, offset, command?, failed_component?}`. `state` is `running`, `done`, `failed` or `needs_password`. `log` holds bytes from `from` (a byte offset) to the end; `offset` is the next `from`. The log keeps the newest 256 KiB |

Poll `setup.job` about once a second with the last `offset`. The daemon keeps only the most recent job, so an unknown id is `not_found`. Errors: code `-32024` (`SETUP_ERROR`) with `error.data.reason`: `busy` or `not_found`.

**PATH.** At start the daemon puts `<data dir>/tools/bin` first on its `PATH`, before the runtime starts, so the tools reach agents and terminals. Then it appends, at the end and only when they exist and are not on `PATH` yet, the folders where a user's agent CLIs live: `~/.local/bin`, `~/.grok/bin`, `~/.claude/local`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.cargo/bin`, `~/.deno/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/home/linuxbrew/.linuxbrew/bin`. A service starts with a short `PATH` that has none of them (code: `setup::with_user_bins`). The data dir is `--home`, else `$BANDITO_HOME`, else `~/.bandito`. One value, set by `main` at start, is read by everything under the data dir (PATH, tools, screens, browser, the run folder).

## Commands

Slash commands in an agent's chat. The daemon lists what an agent can run, and a message that starts with `/name` reaches every runtime. Code: `daemon/src/commands.rs` (discovery, expansion, install), `daemon/src/rpc/commands.rs` (methods). Feature string: `"commands"`.

**Discovery.** For an agent whose folder is `cwd`, and the daemon user's home:

| source | files | name |
|---|---|---|
| `project` | `<cwd>/.claude/commands/**/*.md` | the path without `.md`, folders joined by `:` (`git/commit.md` is `git:commit`) |
| `user` | `~/.claude/commands/**/*.md` | the same |
| `skill` | `~/.claude/skills/<name>/SKILL.md`, `<cwd>/.claude/skills/<name>/SKILL.md` | front matter `name:`, or the folder name |
| `codex_prompt` | `~/.codex/prompts/*.md` | the file name without `.md` |

Limits: files up to 256 KiB, at most 500 commands per list, folders up to 4 levels below `commands/` or `skills/`, symlinks not followed, names only `[A-Za-z0-9_:.-]` and not starting with a dot. The list is sorted by source (`project`, `user`, `skill`, `codex_prompt`), then by name. When names clash, the first one wins.

Front matter is the YAML block between two `---` lines. The daemon reads top-level `key: value` lines only: `description`, `argument-hint` (or `args`), and `name` for skills. Quotes around a value are removed. Nested and multi-line values are not read.

`runtime_native` is true for Claude commands and skills, because the CLI runs them itself. It is false for Codex, for Grok, and for codex prompts.

**Sending.** A message that starts with `/name`, where `name` is a command for the agent, is handled like this:

- Claude and a native command: the text goes to the CLI as typed.
- Anything else: the runtime gets the expansion. The thread keeps what the person typed (`message.user.text`) and the command name (`message.user.command`).
- An unknown `/x` goes as typed, and the CLI deals with it.

This applies to messages from people (`agents.send`) and to schedule prompts. Crew messages are not expanded.

Expansion: the front matter is dropped. `$ARGUMENTS` becomes the whole argument string, and `$1`…`$9` become the words of it. Words are split as a shell does for simple cases: spaces separate them, `"…"` and `'…'` group them (single quotes are literal), and a backslash escapes the next character. A file without placeholders, given arguments, gets `Arguments: <args>` appended after a blank line. A skill becomes `Use the skill below.`, its body, and `Task: <args>` (the last line only when there are arguments).

**Methods.**

| method | params | result |
|---|---|---|
| `commands.list` | `agent_id` | `[Command]`: `{name, description?, args_hint?, source, path, runtime_native}`, no file content |
| `commands.install` | `scope: "user"\|"project"`, `agent_id` (for `project`), `kind: "command"\|"skill"`, `name`, `files: [{path, content}]` (`content` is base64), `overwrite?` (default false) | `{path}` |

Install writes under the daemon user's home (`user`) or under the agent's folder (`project`). A command is `.claude/commands/<name>.md`, one file (`git:commit` goes to `commands/git/commit.md`). A skill is the folder `.claude/skills/<name>/`, which must contain `SKILL.md`; it takes at most 50 files and 2 MiB decoded in total. File paths are relative and have no `..`. Everything is checked before the first write. Without `overwrite`, an existing command or skill is an error. With it, a skill folder is replaced as a whole. Like the file methods, these are open to any paired device, with the rights of the daemon user.

Errors: code `-32027` (`COMMANDS_ERROR`) with `error.data.reason`: `invalid_name`, `invalid_path`, `invalid_content`, `file_count`, `too_many_files`, `too_large`, `missing_skill_file`, `exists`, `no_home`, `io`. Bad params are `-32602`.

## Workspaces

A workspace is where an agent's CLI runs: on the server itself, or in a Docker container with its own disk, network and limits. Agents can be mixed freely: some share the server, one sits in a container. Code: `daemon/src/workspace.rs` (Docker, the command each runtime runs), `daemon/src/store/workspaces.rs` (rows), `daemon/src/rpc/workspaces.rs` (methods). Feature string: `"workspaces"`.

**Kinds.**

| kind | where the CLI runs | notes |
|---|---|---|
| `shared` | the server, as the daemon's user | built in, always present, cannot be deleted; the default for agents |
| `container` | Docker container `bandito-ws-<id>`, started by Bandito | own disk layer, network `internet` or `none`, optional `cpus` and `memory_mb`, extra `mounts` |

A separate Linux user for a workspace is the next step, not in this version.

**What a container sees.** Each agent's folder and its home (`~/bandito/agents/<slug>/`) are mounted read-write at the same paths they have on the server, so the paths in messages, approvals and checkpoints match. The workspace's own `mounts` are added (host folders, optionally read-only). The CLI logins are mounted read-write: `~/.claude` as `/root/.claude` and `~/.codex` as `/root/.codex`, when they exist, so the agent inside is logged in with the same subscription. Nothing else from the server is mounted: no other project, no daemon socket, no Docker socket. Agent secrets reach the CLI as environment variables, by name.

**Image.** When a container workspace names no `image`, Bandito builds `bandito/workspace:<hash>` once from a fixed Dockerfile: `FROM node:22-bookworm` plus the global npm packages `@anthropic-ai/claude-code@2.1.295` and `@openai/codex@0.162.0`, the versions in `NPM_PINS` (the same table the setup installs from). The tag changes with the Dockerfile. With `image` set, that image is used as it is, and it must have the CLIs on `PATH` and run as root.

**Lifecycle.** A container starts with the first session of an agent in its workspace. Each start checks it: missing → created; stopped → started; settings that differ (image, limits, network, or mounts, including the folders of the agents in the workspace) → recreated. Containers restart with the Docker daemon (`--restart unless-stopped`). Recreation drops the container's own writable layer, so anything installed inside it (apt or npm packages) is lost; folders on the host stay. Recreation also ends the running sessions of the other agents in that container, which resume with their next message. `workspaces.stop` stops the container; the next message starts it again.

**How a CLI runs.** Runtimes build their command as before, then `workspace::confine` moves it into the workspace. For a container that is `docker exec -i -w <cwd> -e NAME… <container> <program> <args…>`, so stdin, stdout and stderr pass through and the JSON protocols do not change. Environment values are not in the argument list: `-e NAME` takes the value from the environment of the docker client, which keeps secrets out of the process list. The crew MCP server is not given to container agents, and `agent.sock` is not mounted, so they have no agent tools. The session token still goes into their environment. This is a known limit: a container agent cannot use the crew, browser or screen tools, and the daemon's `history.*` tools are out of its reach. Approvals, checkpoints and memory keep working, because they run in the daemon on the server against the same folders.

**Security.** A container isolates the files outside its mounts, the network (`none` means no network at all) and the CPU and memory it may use. It does not isolate the CLI logins: `~/.claude` and `~/.codex` are writable inside, so an agent in a container can read and change that subscription login. A mount may not be the server root, the Docker socket, or a path with `..`, `,` or `"`. Nor may it be Bandito's own data folder (`$BANDITO_HOME`, or `~/.bandito`), a folder inside it, or a folder that holds it (such as the home folder). Membership of the `docker` group is root-equivalent on the server, so the daemon's user holds that power whenever a container workspace exists.

**Docker.** Bandito uses the `docker` program from `PATH` and runs `docker info` before each start. Without Docker, or when it does not answer, the error is `docker_unavailable` and it names the install guide. The `containers` feature of [Setup](#setup) shows the same check.

**Methods.**

| method | params | result |
|---|---|---|
| `workspaces.list` | `{}` | `[Workspace + {agents: [ids], status}]`. `status` is `null` for `shared`; for a container it is `{running, container_id, cpu, mem}`, or `{running: false, error}` when Docker cannot answer |
| `workspaces.create` | `{name, kind: "shared"\|"container", image?, cpus?, memory_mb?, network?: "internet"\|"none", mounts?: [{host, target, read_only?}]}` | `Workspace` |
| `workspaces.update` | `{id, name?, image?, cpus?, memory_mb?, network?, mounts?}`; `null` clears `image`, `cpus` or `memory_mb` | `Workspace`. Limits and mounts apply at the container's next start |
| `workspaces.delete` | `{id}` | `{deleted: true}`. Removes the container of an empty workspace first |
| `workspaces.start`, `workspaces.stop` | `{id}` | `status` (container workspaces only) |

`agents.create` and `agents.update` take `workspace_id` (default `shared`). Moving an agent starts a new chapter, as a folder change does.

`agents.create` with no `cwd`, or an empty one, runs the agent in its own folder: the folder is made first, and its path becomes the agent's `cwd`. A `cwd` that is given must exist on the server, as before. Clients show that a folder is optional when `daemon.info.features` contains `"agent_own_folder"`.

Limits: name 1–64 characters; `cpus` 0.1–64; `memory_mb` 64–262144; mounts are absolute paths without `,`, `"` or `..`. The shared workspace has no container settings, so it refuses them.

Errors: code `-32028` (`WORKSPACE_ERROR`) with `error.data.reason`: `docker_unavailable`, `not_found`, `builtin` (the shared workspace cannot be deleted), `not_empty` (agents still run in it), `invalid` (bad settings or mount), `docker` (Docker failed; its message is in `message`).

## Team preview

`agents.list`, `agents.get`, `agents.create` and `agents.update` return each agent with three fields the team view needs, without loading its thread:

- `last_message`: the newest user or assistant message, `{role: "user"|"assistant", text, ts}`, or `null`. `text` is cut to 200 characters on a character boundary. Messages Bandito sent itself (`source: "system"`, the wrap-up turn) are skipped, as in `history.search`.
- `status`: the status of the agent's newest `agent.status` event (`idle`, `working`, `needs_you`, `error`, `offline`), or `null` before any.
- `pending_approval_ids`: the ids of the agent's approvals that still wait for an answer (`approvals.status = 'pending'`), oldest first.
- `pending_approvals`: the number of those ids, for clients that only count.

The daemon reads them in one query per list: correlated subqueries per agent (`store/agents.rs`, `LAST_MESSAGE_SQL`, `STATUS_SQL`, `PENDING_IDS_SQL`). The status lookup uses `events_agent_kind_seq`, and the pending ids `approvals_agent_status`, both from migration 0010; the message lookup uses `events_agent_seq`. The daemon's own checks use `agent_get` and `agent_list`, which do not read these fields; the RPC reads use `agent_view` and `agent_list_view`.

Clients keep the fields current from live events: `message.user` and `message.assistant` (not `system`) replace `last_message`; `agent.status` replaces `status`; `approval.requested` adds its id to the agent's pending set and `approval.resolved` removes it. The count is the size of that set, so an event that arrives twice (a replay) changes nothing. A daemon that sends only `pending_approvals` (a number) is counted by live events alone.

Before a thread is open, the app shows the agent's preview from `last_message`, and the status and pending count from these fields. A thread that is loaded wins for its own messages.

A daemon from before this section sends none of the three fields. A missing `last_message` (the key absent, not `null`) makes the app read the newest page of events (40 events) for that agent once, in the background, to build the preview. The status then comes from the thread's live events, and the pending count from the approvals the app has seen.

## Mac app

SwiftUI, macOS 14+. Sidebar: servers → crew. Thread view rendered from events; approval cards with Approve / Deny / Always; schedules; connection wizard. Menu bar item with the status dot. Local notifications with Approve / Deny actions while the app runs. Strings in a String Catalog, 9 languages. Colors from `brand/tokens/dist`.

## Mac app updates

The Mac app updates itself with Sparkle 2 (SwiftPM, exact version 2.10.0 in `apps/mac/project.yml`). Only the app target links Sparkle: `apps/mac/Bandito/App/AppUpdater.swift`. Kit and UI know the settings (`AppUpdatePreferences`) and the menu item (`AppUpdateCommands`, under About), not Sparkle.

- **Feed.** `https://bandito.dev/appcast.xml` (`SUFeedURL`), the file `public/appcast.xml` of the platform repo. The site serves it as `application/rss+xml; charset=utf-8` with `Cache-Control: public, max-age=300`. An item has `sparkle:version` (the build number: the commit count of the release commit), `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` 14.0 and an enclosure on the GitHub release `v<version>`. A version with `-beta.N` also gets `<sparkle:channel>beta</sparkle:channel>`.
- **Trust.** Archives are checked with EdDSA: `SUPublicEDKey` in `project.yml` is the public key. The private key is in the login Keychain of the Mac that releases the app (made with Sparkle's `generate_keys`). It is never exported, printed or committed. Sparkle refuses an archive whose signature does not match.
- **Channels.** Stable takes the items without a channel. Beta also takes the `beta` items. The choice is `updates.channel` in Settings → General. Automatic checks (once a day, Sparkle's default) are `SUEnableAutomaticChecks`, on by default. Nothing installs without the user's OK in Sparkle's own window.
- **Release.** `apps/mac/scripts/release-app.sh <version> [--dry-run]` writes the version into `project.yml`, builds Release with the Developer ID identity of team 74Q24ZMD7A and the hardened runtime, and signs Sparkle's nested code inside out (the XPC services, `Autoupdate`, `Updater.app`, the framework, then the app; no `--deep`). It notarizes the zip with the `bandito-notary` keychain profile, staples the app, builds the `.dmg` (signed, notarized, stapled), signs the final zip with `sign_update`, and adds the appcast item to the platform checkout. It uploads nothing and deploys nothing. `--dry-run` stops before Apple's notary service. Artifacts go to `apps/mac/build/release/` (not committed). The Sparkle tools are read from `~/.cache/sparkle/2.10.0/extracted/bin`; the release must not run from a dirty tree.
- **Daemon update.** The Server screens offer the daemon's own update from `daemon.info.update` (see [Self-update](#self-update)): a card in Server → Overview with a confirmation, then `daemon.update_apply`, then waiting for the daemon to report the new version (two minutes at most). A dot next to a server in the server menu marks a daemon with an update. The app re-reads `daemon.info` once an hour and when Server opens. The GitHub hint in Overview is only a fallback for a daemon that has not reported a check.

## Repo layout

```
daemon/            Rust crate `bandito`
  src/main.rs      CLI entry
  src/service.rs   user service: systemd unit, launchd plist, background fallback
  src/rpc/         JSON-RPC, transports, auth, pairing
  src/store/       SQLite + migrations
  src/runtime/     process.rs (shared child-process plumbing), claude.rs, codex.rs, grok.rs, api/
  src/policy.rs    approval rules: protected paths, risky checks (see Approvals)
  src/shell.rs     reads a command line for the policy: simple commands, wrappers, redirections
  src/host.rs      host load, processes, ports, kill (see Host)
  src/setup.rs     components per feature, install jobs (see Setup)
  src/browser.rs   the server's Chrome: start, stop, agent actions, risky clicks (see Browser)
  src/cdp.rs       DevTools WebSocket client, page operations, snapshot text
  src/rpc/browser.rs  browser.* and browser.agent.* methods
  src/rpc/preview.rs  preview proxy to loopback ports (see Preview proxy)
  src/screen.rs    the server's virtual desktop (see Screen)
  src/rpc/screen.rs  screen.* methods
  src/commands.rs  slash commands: discovery, expansion, install (see Commands)
  src/workspace.rs where CLIs run: the server or a Docker container (see Workspaces)
  src/scheduler.rs
  src/crew.rs      MCP server
  tests/fixtures/  recorded protocol transcripts
apps/mac/          Xcode project
scripts/install.sh
```

## MVP milestones

1. Core: store, events, agents CRUD, RPC over unix socket and WebSocket, tokens, pairing.
2. Claude runtime + policy engine.
3. Codex and Grok runtimes.
4. Scheduler + crew MCP.
5. Mac app: connections (local, SSH, Tailscale, direct), crew, thread, approvals, notifications.
6. Install script, systemd/launchd service, release builds; tested on a real Linux box.
7. API-key runtime.

## Extending Bandito (contributions land on every platform)

Bandito is built so a PR adds something once and every client gets it.

**Behavior lives in the daemon.** Policy, scheduling, crew, runtimes, history: all server-side. Clients render state and send intents over RPC, so a new capability is implemented once. `daemon.info` returns `features` (strings like `"schedules"`, `"crew"`); clients show a feature only when the server has it, so new apps work with old daemons and the other way round.

**Apple clients share one core.** `apps/mac/BanditoKit` (Swift package: models, RPC client, thread reducer, server model, design tokens, strings) is used by the Mac app and the future iPhone app. Platform targets hold only views.

**One source of strings.** `i18n/en.json` is the reference; every language is one file next to it (`i18n/ru.json`, …) and is listed in `i18n/languages.json`. Keys are flat and dotted (`thread.approve`). Plurals are objects with CLDR categories (`{"one": "…", "other": "…"}`), placeholders are `{name}`; a placeholder named `count` is an integer, any other is text. `i18n/build.py` generates platform files (now: `Resources/<code>.lproj/Localizable.strings` and `.stringsdict` + typed `L10n` accessors in BanditoKit; later Android `strings.xml`, web JSON). CI fails if a language has missing or extra keys, placeholders that differ from English, or generated files that are out of date. A missing translation falls back to English at runtime.

**Protocol is described, not implied.** The daemon's RPC types are the contract; `docs/ARCHITECTURE.md#rpc` lists methods, and types for non-Swift clients will be generated from a JSON Schema exported by the daemon.

## Memory and context (keeping long chats cheap)

A chat with an agent can run for weeks. If one CLI session carried all of it, every message would resend a growing context and cost more each time. Bandito keeps the **conversation** (our event log, shown in the app as one continuous thread) separate from the **session** (what the CLI holds in its context window).

**Chapters.** A session is one chapter of the thread. When a chapter gets long, Bandito closes it and the next message starts a fresh, small session. The user sees one thread with a quiet "New chapter · memory saved" line; nothing is lost.

Per agent `memory_mode`:

| mode | when a new chapter starts | for |
|---|---|---|
| `smart` (default) | context passes `context_budget` tokens (default 120 000), or the first message after 04:00 local when the last turn was yesterday | almost everyone |
| `daily` | every first message after 04:00 local | assistants with daily routines |
| `full` | never; the CLI compacts on its own | short projects, debugging one long task |

Before a chapter closes, the daemon sends a wrap-up turn shown in the thread as a quiet line (`source: "system"`), excluded from history search: *update your memory files with what matters from this chapter*. Then the session is dropped and `session.rotated` is emitted. The check runs when the next message arrives, so an idle agent costs nothing, and that message waits while the wrap-up runs. If the CLI session has gone, Bandito resumes it for the wrap-up. If it cannot resume, the chapter closes without a wrap-up and the thread says `memory not saved`.

**Agent home.** Every agent gets its own folder on the server, `~/bandito/agents/<slug>/`, next to (not inside) the project it works on. The root is `$BANDITO_AGENTS_DIR` when it is set to an absolute path; otherwise, when the daemon runs with its own `--home` (and not `~/.bandito`), it is `<home>-agents/` next to the data folder (never inside it: agents may not touch Bandito's own files), so a second daemon never writes into the first one's folders. `<slug>` is the agent's name in lowercase ASCII: Cyrillic is transliterated (`Ёж` → `yozh`, `Щи` → `shchi`, `ъ` and `ь` are dropped), other letters are dropped, and any other character becomes `-`. An empty result is `agent`. A name taken by another agent gets `-2`, `-3`, and so on:

```
MEMORY.md        short index, read at the start of every chapter (≤ 200 lines)
notes/<topic>.md details: decisions, how things work, people, preferences
journal/<date>.md one line per finished piece of work
files/           anything the agent makes for itself
```

The agent's instructions (built by the daemon, before the user's own) explain this layout. The CLI is allowed to write there (`--add-dir` for Claude, writable roots for Codex). The user can open, edit or delete these files; they are plain Markdown. The root can be moved with `BANDITO_AGENTS_DIR`, which must be an absolute path (a relative one is ignored with a warning).

**Grok.** Grok does not report context size, so Grok agents start new chapters by day only. Its CLI has no extra-folder flag: the approval policy decides whether the agent may act (allow or ask), and the CLI's own sandbox limits access to the home folder.

**Recall instead of remembering.** The crew MCP server also offers `history_search{query}` and `history_day{date}` over the agent's own past messages in the daemon's database, so an agent looks up what was said weeks ago instead of carrying it.

**Changing an agent.** `agents.update` applies name, role, model, effort, system prompt, memory mode, context budget, folder, runtime, fallback, workspace and capabilities from the next session: an idle agent's session is closed at once, a running one when its turn ends. The chapter goes on, except after a folder, runtime or workspace change, which starts a new chapter (a CLI session is tied to its folder, its runtime and where it runs; see [Workspaces](#workspaces)). A runtime change also resets effort to null, with a `warnings` entry in the response, when the new runtime does not offer the old level. The approval mode is read on every request and needs no restart.

**Effort.** Each agent has an `effort` (`low`, `medium`, `high`, `xhigh`, `max`). The daemon maps it to the runtime (`--effort` for Claude, the turn's `effort` for Codex, `--reasoning-effort` for Grok) and refuses levels a runtime does not offer.

**Usage.** Rate-limit windows reported by the CLIs are cached per runtime (`usage.limits`), so the app shows remaining quota even when no turn is running; `usage.refresh` asks runtimes that can be asked (Codex: `account/rateLimits/read`).

**Plan.** The subscription of each runtime's account is cached next to its windows, as `plan: {id, label}` (Claude `max_20x` / «Max ×20», `max_5x` / «Max ×5», `max` / «Max», `pro`; ChatGPT `plus`, `pro`, `team`, …), or `null` when unknown. `usage.refresh` asks for it in the same call as the windows, with the same timeout, and never starts a turn:

- Claude: read from `<config_dir>/.credentials.json`, where `config_dir` is `CLAUDE_CONFIG_DIR` or else `$HOME/.claude`. Only `subscriptionType` and `rateLimitTier` are read. The OAuth tokens in that file are never deserialized, logged or returned. On macOS the CLI keeps its login in the Keychain and writes no file, so the plan stays unknown there.
- Codex: a separate `codex app-server` for `initialize` → `account/read` (`account.planType`).
- Grok and API keys: no plan yet.

A runtime that reports no plan, or fails, leaves the stored plan as it was.

## Fallback subscription

An agent can name a fallback runtime (`fallback_runtime`, one of `claude`, `codex`, `grok`, different from its `runtime`) and a `fallback_model` for it. It is used when the primary runtime's subscription runs out of usage. `agents.create` and `agents.update` take both (`null` clears them), and `agents.get`/`agents.list` return `active_runtime`: the runtime the agent runs on now, `null` for the primary one.

**Recognising a limit.** A turn that ends with an error, and whose runtime reported its usage as used up during it:

| runtime | error message (case-insensitive) | or usage reported |
|---|---|---|
| Claude | `usage limit` (`Claude AI usage limit reached…`), `rate limit`, `rate_limit`, `429` | `rate_limit_event` window at utilization 1.0 or more |
| Codex | `usage_limit_reached`, `usage limit` | `account/rateLimits/updated` window at `usedPercent` 100 or more |
| Grok | `rate limit` (`Rate limited: …`), `429`, `too many requests` | none |

Only runtime error messages are checked, never the agent's text. The message is the one the adapter reports, so a runtime that words its limit differently is not recognised.

**Switching.** When the limit is recognised, the fallback is free, and the turn had no retry yet, the daemon:

1. closes the session and starts a new chapter (`session.rotated`, reason `runtime switched`). The memory carries over in the agent's files, so no wrap-up turn runs;
2. sets `active_runtime` to the other runtime and emits `runtime.switched {from, to, until?}`;
3. sends the same message again on the new runtime. The thread shows the user's message once. A retry that hits the limit again is a plain error: one switch per message.

Without a fallback, or when the fallback is out of usage too, the turn is an ordinary error.

**Coming back.** Before a message goes out, an agent on its fallback returns to the primary runtime once that runtime's windows do not block: a full window (utilization 1.0 or more) blocks while its `resets_at` is in the future. A full window with no reset time blocks for one hour after it was reported; after that the primary runtime is tried again, and if its limit is still there, the message switches to the fallback again. The return emits `runtime.switched {from: fallback, to: primary}` and starts a new chapter.

**Usage cache.** The runtime left is recorded as used up: its own windows if it reported them, else a window named `limit` at 100% with no reset time. The app shows that window under the runtime's usage.

**Changing the primary runtime.** `agents.update {runtime}` checks that the runtime is installed on this server, clears `active_runtime`, starts a new chapter (`session.rotated`, reason `runtime changed`) and drops the CLI session. The fallback must differ from the new runtime: switching to the current fallback is refused unless the same patch clears it.

**Limits of this design.** Codex limits are recognised by the words in the error message the adapter passes on. A switch does not run a wrap-up turn, so what the agent did not write to its memory files during the chapter is not saved.

## Accounts, sync and push (planned)

An account is optional: without one the app works on one Mac. With one, every device of the person sees the same servers and agents, and approvals reach the phone.

**Service.** `api.bandito.dev` (Cloudflare Worker + D1, in the private `platform` repo; the protocol is documented here so anyone can run their own). Sign in with Apple, GitHub, or an email link. No passwords.

**What the service stores.** Account (id, email), devices (name, platform, public key, push token), and one **encrypted vault** per account. The vault holds the server list (names, how to reach them) and per-device settings. It is encrypted on the device with a vault key the service never sees.

**Vault key.** Created on the first device and kept in the Keychain. A new device signs in, shows a short code, and an existing device approves it: the existing device encrypts the vault key to the new device's public key (X25519 + XChaCha20-Poly1305). An optional printed recovery key restores the vault if every device is lost; without it the person re-pairs servers, and nothing on the servers is lost.

**Server access per device.** Devices never share daemon tokens. When a device joins, an existing device asks each server for a pairing code (`pair.create`) and passes it through the vault channel; the new device redeems it for its own token. Revoking a device revokes only its tokens.

**Push.** Approvals and finished turns reach phones through `push.bandito.dev`: the daemon sends an end-to-end encrypted payload addressed to device push tokens; a notification service extension decrypts it on the phone. Approve and Deny from the notification call the daemon directly (through whatever connection the phone has: Tailscale, SSH, relay).

**Reaching servers from a phone.** Tailscale and direct TLS work as on the Mac; SSH works through an in-app SSH client; the Bandito Relay (outbound-only, end-to-end encrypted) covers servers behind NAT without any setup.

## Screen

A virtual desktop on a Linux server that people see in the app and agents can drive. `daemon/src/screen.rs` runs it; `daemon/src/rpc/screen.rs` is the RPC layer. Other systems answer `unsupported`.

**Lifecycle.** `screen.start {workspace?, width?, height?}` starts `Xvfb` on the first free display from `:90`, `openbox` when it is installed, and `x11vnc` bound to `127.0.0.1` on a free port with a random password (file mode 0600 under `$BANDITO_HOME/screens/<workspace>/`). Before Xvfb starts, `xauth -f FILE source -` writes the folder's `Xauthority` with one `MIT-MAGIC-COOKIE-1` of 16 random bytes for the display. The cookie goes to xauth on stdin, not in its arguments, so it does not show in the process list (mode 0600; a file from a crashed screen is replaced). Xvfb runs with `-auth` on it, and x11vnc with `-auth`. Every program on the screen (openbox, x11vnc, `screen.launch`, and the agent tools) gets `DISPLAY` and `XAUTHORITY`, so another local user cannot open the screen. `screen.stop` removes the file. `xauth` and `x11vnc -storepasswd` run with umask 077, and the folder is 0700 even when it existed before. Each process has its own process group; x11vnc is restarted once if it dies. `screen.status` returns `{running, display, width, height, vnc_port, vnc_password, started_at, controller, idle_ms}`; `screen.stop` ends it. A screen with no VNC client and no agent tool call for 30 minutes stops by itself. The daemon stops every screen when it shuts down.

**Viewing.** The app calls `screen.start`, then opens `/v1/tunnel?port=<vnc_port>` through a one-shot local forwarder and speaks VNC with the password. The password is 8 characters, the whole of what RFB uses (it reads only the first 8). They come from the system RNG as printable ASCII without `"` and `\` (92 symbols), by rejection sampling, so no symbol is favored. The tunnel is what keeps the screen private (loopback only, paired device only).

**Agents.** The crew MCP server offers `screen_screenshot` (PNG, at most 1280 px wide, with the original size so clicks use screen pixels), `screen_click {x, y, button?, double?}`, `screen_move`, `screen_type {text}`, `screen_key {keys}`, `screen_scroll {direction, amount?}` and `screen_launch {command}`. They call `screen.agent.*` methods, which only agents may call and start the screen when it is off.

**Control.** `screen.control {holder: user|agent|none}`. While the user holds the screen, agent tools fail with a message asking the agent to wait or ask for it back.

**Needs** `xvfb`, `x11vnc`, `xdotool`, `xauth`, `imagemagick` (`import`, `convert`) and optionally `openbox` (see [Setup](#setup)). A missing one is `SCREEN_ERROR` (`-32025`) with `data.reason = "missing_component"` and `data.component`. Feature string: `"screen"` (Linux only).
