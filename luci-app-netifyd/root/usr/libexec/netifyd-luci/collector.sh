#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Connects to netifyd's local JSON socket (see /etc/netifyd.conf [socket]
# section), keeps one small file per active flow under a tmpfs scratch
# directory, and periodically aggregates them into a single snapshot that
# /usr/libexec/rpcd/luci.netifyd reads back. Splitting ingestion (cheap,
# per-event) from aggregation (periodic, batch) avoids re-merging the whole
# flow table on every socket message.

. /lib/functions.sh

RUN_DIR="/var/run/netifyd-luci"
FLOWS_DIR="$RUN_DIR/flows"
SNAPSHOT="$RUN_DIR/snapshot.json"
AGENT_FILE="$RUN_DIR/agent.json"
STATUS_FILE="$RUN_DIR/status.json"

config_load netifyd-luci
config_get SOCKET_PATH main socket_path "/var/run/netifyd/netifyd.sock"
config_get POLL_INTERVAL main poll_interval 5
config_get IDLE_TTL main idle_ttl 300

mkdir -p "$FLOWS_DIR"
: > "$AGENT_FILE"

write_status() {
	# $1 = 0/1 connected, $2 = human message
	jq -n --argjson connected "$1" --arg message "$2" --argjson now "$(date +%s)" \
		'{connected: $connected, message: $message, updated_at: $now}' \
		> "$STATUS_FILE.tmp" 2>/dev/null && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

sanitize_digest() {
	printf '%s' "$1" | tr -cd 'A-Za-z0-9_-'
}

merge_agent_field() {
	# $1 = json line for an agent_hello/agent_status message
	[ -s "$AGENT_FILE" ] || echo '{}' > "$AGENT_FILE"
	jq -n --argjson base "$(cat "$AGENT_FILE")" --argjson new "$1" '$base * $new' \
		> "$AGENT_FILE.tmp" 2>/dev/null && mv "$AGENT_FILE.tmp" "$AGENT_FILE"
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
			type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
			case "$type" in
			flow)
				digest=$(printf '%s' "$line" | jq -r '.flow.digest // empty' 2>/dev/null)
				[ -z "$digest" ] && continue
				digest=$(sanitize_digest "$digest")
				[ -z "$digest" ] && continue
				printf '%s' "$line" | jq -c --argjson now "$(date +%s)" '.flow + {seen_at:$now}' \
					> "$FLOWS_DIR/$digest.json.tmp" 2>/dev/null &&
					mv "$FLOWS_DIR/$digest.json.tmp" "$FLOWS_DIR/$digest.json"
				;;
			agent_hello|agent_status)
				merge_agent_field "$line"
				;;
			esac
		done

		write_status 0 "disconnected, reconnecting"
		sleep 3
	done
}

prune_stale_flows() {
	local now cutoff f seen_at
	now=$(date +%s)
	cutoff=$((now - IDLE_TTL))

	for f in "$FLOWS_DIR"/*.json; do
		[ -e "$f" ] || continue
		seen_at=$(jq -r '.seen_at // 0' "$f" 2>/dev/null)
		[ "${seen_at:-0}" -lt "$cutoff" ] && rm -f "$f"
	done
}

build_snapshot() {
	local now agent
	now=$(date +%s)
	agent=$(cat "$AGENT_FILE" 2>/dev/null)
	[ -n "$agent" ] || agent='{}'

	jq -cs --argjson now "$now" --argjson agent "$agent" '
		def bytes_of: (.total_bytes // ((.local_bytes // 0) + (.other_bytes // 0)));
		def group_summary(f):
			group_by(f) | map({
				key: (.[0] | f) // "unknown",
				flows: length,
				bytes: (map(bytes_of) | add // 0)
			}) | sort_by(-.bytes);
		{
			generated_at: $now,
			agent: $agent,
			flow_count: length,
			total_bytes: (map(bytes_of) | add // 0),
			by_protocol: group_summary(.detected_protocol_name // "unknown"),
			by_application: group_summary(.detected_application_name // "unclassified"),
			by_category: group_summary(.category.application // .category.domain // .category.protocol // "uncategorized"),
			top_talkers: (group_summary(.other_ip // "unknown") | .[0:20]),
			flows: (sort_by(-(bytes_of)))
		}
	' "$FLOWS_DIR"/*.json > "$SNAPSHOT.tmp" 2>/dev/null

	if [ ! -s "$SNAPSHOT.tmp" ]; then
		printf '{"generated_at":%s,"agent":%s,"flow_count":0,"total_bytes":0,"by_protocol":[],"by_application":[],"by_category":[],"top_talkers":[],"flows":[]}\n' \
			"$now" "$agent" > "$SNAPSHOT.tmp"
	fi

	mv "$SNAPSHOT.tmp" "$SNAPSHOT"
}

aggregator_loop() {
	while :; do
		sleep "$POLL_INTERVAL"
		prune_stale_flows
		build_snapshot
	done
}

cleanup() {
	kill "$reader_pid" "$agg_pid" 2>/dev/null
	exit 0
}

trap cleanup TERM INT

reader_loop &
reader_pid=$!

aggregator_loop &
agg_pid=$!

wait
