-- Workspaces: where an agent's CLI runs. `shared` is the server's own user environment and
-- always exists. A `container` workspace is a Docker container (see docs/ARCHITECTURE.md#workspaces).
CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('shared', 'container')),
    image TEXT,
    cpus REAL,
    memory_mb INTEGER,
    network TEXT NOT NULL DEFAULT 'internet' CHECK (network IN ('internet', 'none')),
    mounts TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL
);

INSERT INTO workspaces (id, name, kind, network, mounts, created_at)
VALUES ('shared', 'Shared', 'shared', 'internet', '[]', 0);

-- No foreign key: SQLite does not allow one on a column whose default is not NULL.
-- Existence is checked by the RPC layer and in `agent_create_in` / `agent_update`.
ALTER TABLE agents ADD COLUMN workspace_id TEXT NOT NULL DEFAULT 'shared';
