-- A schedule's short name, given by the owner or by the agent (`schedule_create{title}`). NULL = none.
ALTER TABLE schedules ADD COLUMN title TEXT;
