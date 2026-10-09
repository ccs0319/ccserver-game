-- 0001_init.lua — create the player table.
return {
    up = {
        [[CREATE TABLE player (
            uid   BIGINT PRIMARY KEY,
            name  VARCHAR(64) NOT NULL,
            level INT NOT NULL DEFAULT 1
        )]],
    },
    down = {
        [[DROP TABLE player]],
    },
}
