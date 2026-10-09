-- 0002_add_created_at.lua — add a creation timestamp column.
return {
    up = {
        [[ALTER TABLE player ADD COLUMN created_at VARCHAR(32)]],
    },
    down = {
        [[ALTER TABLE player DROP COLUMN created_at]],
    },
}
