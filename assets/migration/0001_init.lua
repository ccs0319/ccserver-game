-- 0001_init.lua — create the player table.
return {
    [[CREATE TABLE player (
        uid   BIGINT PRIMARY KEY,
        name  VARCHAR(64) NOT NULL,
        level INT NOT NULL DEFAULT 1
    )]],
}
