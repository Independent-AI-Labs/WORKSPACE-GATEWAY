-- sse-usage.lua: per-request usage row, buffered async insert.
INSERT INTO {{ DB }}.usage_log SETTINGS async_insert = 1, wait_for_async_insert = 1, async_insert_busy_timeout_ms = 10000 FORMAT JSONEachRow
