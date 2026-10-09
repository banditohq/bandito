CREATE TABLE agents (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL DEFAULT '',
    runtime TEXT NOT NULL,
    model TEXT,
    cwd TEXT NOT NULL,
    approval_mode TEXT NOT NULL DEFAULT 'risky',
    system_prompt TEXT,
    runtime_session_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL
);
CREATE INDEX events_agent_seq ON events(agent_id, seq);

CREATE TABLE approvals (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    call_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    title TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    decision TEXT,
    created_at INTEGER NOT NULL,
    resolved_at INTEGER
);
CREATE INDEX approvals_status ON approvals(status, created_at);

CREATE TABLE rules (
    id TEXT PRIMARY KEY,
    agent_id TEXT,
    pattern TEXT NOT NULL,
    action TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE schedules (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    cron TEXT NOT NULL,
    tz TEXT NOT NULL DEFAULT 'UTC',
    prompt TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at INTEGER,
    next_run_at INTEGER,
    created_at INTEGER NOT NULL
);

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER
);

CREATE TABLE pairing (
    code_hash TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
);

CREATE TABLE secrets (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
