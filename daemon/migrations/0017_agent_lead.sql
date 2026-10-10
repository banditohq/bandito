-- The main agent of the crew: the one that hands out work to the others (see docs/ARCHITECTURE.md#lead-agent).
-- At most one agent has it; the index makes the database refuse a second one.
ALTER TABLE agents ADD COLUMN lead INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX agents_one_lead ON agents (lead) WHERE lead = 1;
