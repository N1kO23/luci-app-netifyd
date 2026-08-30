#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Periodically batches the pending rollup/completed-flow records written by
# luci-app-netifyd's collector.sh (the sole reader of netifyd's socket --
# see that script) into SQLite via history-build-sql.jq, and prunes rows
# older than retention_days. Does not talk to netifyd directly: it only
# knows about /var/run/netifyd-history/pending_*.jsonl and the database.

. /lib/functions.sh

RUN_DIR="/var/run/netifyd-history"
STATUS_FILE="$RUN_DIR/status.json"
PENDING_ROLLUPS="$RUN_DIR/pending_rollups.jsonl"
PENDING_FLOWS="$RUN_DIR/pending_flows.jsonl"
SQL_PROGRAM="/usr/libexec/netifyd-luci/history-build-sql.jq"

config_load netifyd-luci-history
config_get DB_PATH main db_path ""
config_get RETENTION_DAYS main retention_days 7
config_get ROLLUP_INTERVAL main rollup_interval 60

mkdir -p "$RUN_DIR"
[ -f "$PENDING_ROLLUPS" ] || : > "$PENDING_ROLLUPS"
[ -f "$PENDING_FLOWS" ] || : > "$PENDING_FLOWS"

write_status() {
	# $1 = human message
	jq -n --arg message "$1" --arg db_path "$DB_PATH" --argjson now "$(date +%s)" \
		'{message: $message, db_path: $db_path, updated_at: $now}' \
		> "$STATUS_FILE.tmp" 2>/dev/null && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

init_db() {
	[ -n "$DB_PATH" ] || return 0
	sqlite3 "$DB_PATH" <<-'SQL'
	PRAGMA journal_mode=WAL;
	PRAGMA synchronous=NORMAL;
	CREATE TABLE IF NOT EXISTS flows (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		digest TEXT NOT NULL,
		started_at INTEGER NOT NULL,
		ended_at INTEGER NOT NULL,
		local_ip TEXT, local_port INTEGER,
		other_ip TEXT, other_port INTEGER,
		protocol TEXT, application TEXT, category TEXT,
		host_server_name TEXT,
		total_bytes INTEGER NOT NULL DEFAULT 0,
		total_packets INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX IF NOT EXISTS idx_flows_ended_at ON flows(ended_at);
	CREATE INDEX IF NOT EXISTS idx_flows_other_ip ON flows(other_ip);
	CREATE TABLE IF NOT EXISTS rollups (
		bucket_start INTEGER NOT NULL,
		dimension TEXT NOT NULL,
		key TEXT NOT NULL,
		bytes INTEGER NOT NULL DEFAULT 0,
		packets INTEGER NOT NULL DEFAULT 0,
		flows INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (bucket_start, dimension, key)
	);
	CREATE INDEX IF NOT EXISTS idx_rollups_bucket ON rollups(bucket_start);
	SQL
}

flush_pending() {
	[ -n "$DB_PATH" ] || return 0
	[ -s "$PENDING_ROLLUPS" ] || [ -s "$PENDING_FLOWS" ] || return 0

	rollups_batch="$RUN_DIR/rollups.batch.jsonl"
	flows_batch="$RUN_DIR/flows.batch.jsonl"

	rm -f "$rollups_batch" "$flows_batch"
	if [ -s "$PENDING_ROLLUPS" ]; then
		mv "$PENDING_ROLLUPS" "$rollups_batch"
	else
		: > "$rollups_batch"
	fi
	if [ -s "$PENDING_FLOWS" ]; then
		mv "$PENDING_FLOWS" "$flows_batch"
	else
		: > "$flows_batch"
	fi

	jq -n -r --slurpfile rollups "$rollups_batch" --slurpfile flows "$flows_batch" \
		-f "$SQL_PROGRAM" > "$RUN_DIR/batch.sql" 2>/dev/null

	if [ -s "$RUN_DIR/batch.sql" ]; then
		sqlite3 "$DB_PATH" < "$RUN_DIR/batch.sql"
	fi

	rm -f "$rollups_batch" "$flows_batch" "$RUN_DIR/batch.sql"
}

writer_loop() {
	if [ -z "$DB_PATH" ]; then
		write_status "no db_path configured"
	else
		init_db
		write_status "writing to $DB_PATH"
	fi

	while :; do
		sleep "$ROLLUP_INTERVAL"
		[ -n "$DB_PATH" ] && flush_pending
	done
}

retention_loop() {
	while :; do
		sleep 3600
		[ -n "$DB_PATH" ] || continue
		cutoff=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
		sqlite3 "$DB_PATH" \
			"DELETE FROM flows WHERE ended_at < $cutoff; DELETE FROM rollups WHERE bucket_start < $cutoff;"
	done
}

cleanup() {
	kill "$writer_pid" "$retention_pid" 2>/dev/null
	exit 0
}

trap cleanup TERM INT

writer_loop &
writer_pid=$!

retention_loop &
retention_pid=$!

wait
