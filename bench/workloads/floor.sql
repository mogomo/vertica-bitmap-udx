-- Latency floor and client headroom: a statement that does no work, at every concurrency level.
-- Its latency is the fixed cost of one round trip through the client and the engine; the client
-- CPU use recorded with the run shows whether the client cores can drive 32 sessions.
-- @engine vertica

-- @query floor.select1 answer=floor oracle
SELECT 1;
