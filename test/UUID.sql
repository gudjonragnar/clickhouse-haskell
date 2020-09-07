CREATE TABLE IF NOT EXISTS universal (
    `id` Nullable(FixedString(10)),
    `uid` UUID
) 
ENGINE = MergeTree()
ORDER BY tuple();