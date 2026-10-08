-- 0002_add_created_at.lua — add a creation timestamp column.
return {
    [[ALTER TABLE player ADD COLUMN created_at VARCHAR(32)]],
}
