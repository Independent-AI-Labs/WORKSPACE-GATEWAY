-- crunch-usefulness.sh --rebuild: drop before recreating from canonical DDL.
DROP TABLE IF EXISTS {{ DB }}.request_signals
