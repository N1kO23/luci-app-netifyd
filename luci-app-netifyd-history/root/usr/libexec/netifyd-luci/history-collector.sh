#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Independent second client of netifyd's local JSON socket (see
# luci-app-netifyd's collector.sh for the live-dashboard counterpart --
# netifyd supports multiple simultaneous socket clients, and this one is
# deliberately decoupled from that package: it only reads from it, never
# writes to its state, and can fail without affecting the live dashboard).
#
# Caches per-flow metadata just long enough to attribute flow_stats/
# flow_purge byte deltas to a protocol/application/category, buffers those
# deltas plus completed-flow records, and periodically batches them into a
# SQLite database via history-build-sql.jq for persistent history.

. /lib/functions.sh

RUN_DIR="/var/run/netifyd-history"
ACTIVE_DIR="$RUN_DIR/active"
STATUS_FILE="$RUN_DIR/status.json"
PENDING_ROLLUPS="$RUN_DIR/pending_rollups.jsonl"
PENDING_FLOWS="$RUN_DIR/pending_flows.jsonl"
SQL_PROGRAM="/usr/libexec/netifyd-luci/history-build-sql.jq"

# The socket path is netifyd-luci's concern (the base package this one
# depends on); reuse it instead of duplicating/desyncing the setting.
config_load netifyd-luci
config_get SOCKET_PATH main socket_path "/var/run/netifyd/netifyd.sock"

config_load netifyd-luci-history
config_get DB_PATH main db_path ""
config_get RETENTION_DAYS main retention_days 7
config_get ROLLUP_INTERVAL main rollup_interval 60

mkdir -p "$ACTIVE_DIR"
rm -f "$ACTIVE_DIR"/*.json
: > "$PENDING_ROLLUPS"
: > "$PENDING_FLOWS"

TAB=$(printf '\t')

write_status() {
	# $1 = 0/1 connected to netifyd, $2 = human message
	jq -n --argjson connected "$1" --arg message "$2" \
		--arg db_path "$DB_PATH" --argjson now "$(date +%s)" \
		'{connected: $connected, message: $message, db_path: $db_path, updated_at: $now}' \
		> "$STATUS_FILE.tmp" 2>/dev/null && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

sanitize_digest() {
	printf '%s' "$1" | tr -cd 'A-Za-z0-9_-'
}

bucket_start_for() {
	echo $(( $1 - ($1 % ROLLUP_INTERVAL) ))
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

reader_loop() {
	while :; do
		if [ ! -S "$SOCKET_PATH" ]; then
			write_status 0 "netifyd socket not found: $SOCKET_PATH"
			sleep 5
			continue
		fi

		write_status 1 "connected"

		socat -u "UNIX-CONNECT:${SOCKET_PATH}" - 2>/dev/null | jq -c '.' 2>/dev/null |
		while IFS= read -r line; do
			# One combined jq call for type+digest instead of two separate
			# ones: this loop is a strictly serial socket reader running
			# alongside the live-dashboard collector's own reader, so
			# per-event process-spawn overhead directly shows up as lag.
			# Parsed via parameter expansion, not word-splitting -- IFS-
			# based splitting collapses empty fields (e.g. a missing
			# digest for non-flow messages), silently shifting later ones.
			fields=$(printf '%s' "$line" | jq -r '[.type, (.flow.digest // "")] | @tsv' 2>/dev/null)
			type=${fields%%"$TAB"*}
			digest=${fields#*"$TAB"}
			[ -n "$digest" ] && digest=$(sanitize_digest "$digest")

			case "$type" in
			flow)
				[ -z "$digest" ] && continue

				# netifyd still emits "flow" for non-IP traffic (ARP, other
				# L2-only frames) with empty local_ip/other_ip, which has
				# nothing meaningful to log for an IP traffic history.
				meta=$(printf '%s' "$line" | jq -c --argjson now "$(date +%s)" \
					'.flow |
					if ((.local_ip // "") != "" and (.other_ip // "") != "") then
						{
							local_ip, local_port, other_ip, other_port,
							protocol: .detected_protocol_name,
							application: .detected_application_name,
							category: (.category.application // .category.domain // .category.protocol // null),
							host_server_name,
							started_at: $now
						}
					else empty end' 2>/dev/null)

				if [ -n "$meta" ]; then
					printf '%s\n' "$meta" > "$ACTIVE_DIR/$digest.json.tmp" &&
						mv "$ACTIVE_DIR/$digest.json.tmp" "$ACTIVE_DIR/$digest.json"
				fi
				;;
			flow_stats|flow_purge)
				# Without a cached "flow" metadata event there's nothing
				# useful to attribute this delta to -- same rule as the
				# live-dashboard collector's fix for the same reason.
				[ -z "$digest" ] && continue
				[ -s "$ACTIVE_DIR/$digest.json" ] || continue
				meta=$(cat "$ACTIVE_DIR/$digest.json")

				now=$(date +%s)
				bucket=$(bucket_start_for "$now")
				completed=false
				[ "$type" = "flow_purge" ] && completed=true

				# local_bytes/other_bytes are reset to 0 by netifyd after
				# each report, so they're the delta since the last one --
				# exactly what a bucketed rollup needs. total_bytes is the
				# lifetime cumulative counter, used below for the
				# completed-flow row instead.
				printf '%s' "$line" | jq -c --argjson meta "$meta" \
					--argjson bucket "$bucket" --argjson completed "$completed" \
					'.flow as $f | {
						bucket_start: $bucket,
						protocol: $meta.protocol,
						application: $meta.application,
						category: $meta.category,
						bytes: (($f.local_bytes // 0) + ($f.other_bytes // 0)),
						packets: (($f.local_packets // 0) + ($f.other_packets // 0)),
						completed: $completed
					}' >> "$PENDING_ROLLUPS"

				if [ "$type" = "flow_purge" ]; then
					printf '%s' "$line" | jq -c --argjson meta "$meta" \
						--argjson now "$now" --arg digest "$digest" \
						'.flow as $f | {
							digest: $digest,
							started_at: $meta.started_at,
							ended_at: $now,
							local_ip: $meta.local_ip, local_port: $meta.local_port,
							other_ip: $meta.other_ip, other_port: $meta.other_port,
							protocol: $meta.protocol, application: $meta.application,
							category: $meta.category, host_server_name: $meta.host_server_name,
							total_bytes: ($f.total_bytes // 0),
							total_packets: ($f.total_packets // 0)
						}' >> "$PENDING_FLOWS"
					rm -f "$ACTIVE_DIR/$digest.json"
				fi
				;;
			esac
		done

		write_status 0 "disconnected, reconnecting"
		sleep 3
	done
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
	init_db
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
	kill "$reader_pid" "$writer_pid" "$retention_pid" 2>/dev/null
	exit 0
}

trap cleanup TERM INT

reader_loop &
reader_pid=$!

writer_loop &
writer_pid=$!

retention_loop &
retention_pid=$!

wait
