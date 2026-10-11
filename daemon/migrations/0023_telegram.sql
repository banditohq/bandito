-- The Telegram bot (see docs/ARCHITECTURE.md#telegram). The bot's token is a hidden secret, not a column.
-- `answers` is `all`, `telegram` or `none`. A chat is private: its id is the person's own Telegram id.
CREATE TABLE telegram_chats (
    chat_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    language TEXT NOT NULL DEFAULT 'en',
    linked_at INTEGER NOT NULL,
    approvals INTEGER NOT NULL DEFAULT 1,
    answers TEXT NOT NULL DEFAULT 'telegram' CHECK (answers IN ('all', 'telegram', 'none')),
    current_agent TEXT
);
-- The messages the bot sent that a later event or a reply refers to: an agent's answer (`kind` `answer`, so a reply
-- reaches that agent) and an approval card (`approval` while it has buttons, `approval_done` after it was edited).
-- Rows older than 7 days are removed.
CREATE TABLE telegram_messages (
    chat_id INTEGER NOT NULL,
    message_id INTEGER NOT NULL,
    agent_id TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL,
    ref_id TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    PRIMARY KEY (chat_id, message_id)
);
CREATE INDEX telegram_messages_ref ON telegram_messages (kind, ref_id);
CREATE INDEX telegram_messages_created ON telegram_messages (created_at);
-- Small values of the bot: the poll offset, the bot's name and username.
CREATE TABLE telegram_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
