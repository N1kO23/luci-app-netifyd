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

# luci-app-netifyd-history is optional and hard-depends on this package,
# so it's this collector -- the sole socket reader -- that feeds it,
# rather than that package running a second independent connection and
# redoing the same event parsing. config_load on a config file that
# doesn't exist (package not installed) is safe: the config_get calls
# below just fall back to their defaults.
HISTORY_RUN_DIR="/var/run/netifyd-history"
HISTORY_PENDING_ROLLUPS="$HISTORY_RUN_DIR/pending_rollups.jsonl"
HISTORY_PENDING_FLOWS="$HISTORY_RUN_DIR/pending_flows.jsonl"

config_load netifyd-luci-history
config_get_bool HISTORY_ENABLED main enabled 0
config_get HISTORY_ROLLUP_INTERVAL main rollup_interval 60

if [ "$HISTORY_ENABLED" = "1" ]; then
	mkdir -p "$HISTORY_RUN_DIR"
	# Only create if missing -- a collector.sh restart shouldn't discard
	# history data still waiting on history-writer.sh's next flush.
	[ -f "$HISTORY_PENDING_ROLLUPS" ] || : > "$HISTORY_PENDING_ROLLUPS"
	[ -f "$HISTORY_PENDING_FLOWS" ] || : > "$HISTORY_PENDING_FLOWS"
fi

mkdir -p "$FLOWS_DIR"
rm -f "$FLOWS_DIR"/*.json
: > "$AGENT_FILE"

TAB=$(printf '\t')

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

append_history_rollup() {
	# $1 = raw flow_stats/flow_purge event line, $2 = cached flow metadata
	# ($meta -- a FLOWS_DIR record, so it uses netifyd's own field names:
	# detected_protocol_name/detected_application_name/nested category,
	# same as build_snapshot() reads below), $3 = bucket_start,
	# $4 = completed (true/false). local_bytes/other_bytes are the delta
	# since the last report (netifyd resets them after each one), which
	# is exactly what a bucketed rollup needs.
	printf '%s' "$1" | jq -c --argjson meta "$2" --argjson bucket "$3" --argjson completed "$4" \
		'.flow as $f | {
			bucket_start: $bucket,
			protocol: ($meta.detected_protocol_name // "Unclassified"),
			application: $meta.detected_application_name,
			category: ($meta.category.application // $meta.category.domain // $meta.category.protocol // null),
			bytes: (($f.local_bytes // 0) + ($f.other_bytes // 0)),
			packets: (($f.local_packets // 0) + ($f.other_packets // 0)),
			completed: $completed
		}' >> "$HISTORY_PENDING_ROLLUPS" 2>/dev/null
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
			# One combined jq call instead of several: this loop is a
			# strictly serial socket reader, so per-event process-spawn
			# overhead directly shows up as lag on a busy network. Parsed
			# via parameter expansion, not word-splitting -- IFS-based
			# splitting collapses empty fields (e.g. a missing digest for
			# non-flow messages), silently shifting later fields.
			fields=$(printf '%s' "$line" | jq -r \
				'[.type, (.flow.digest // ""), (if ((.flow.local_ip // "") != "" and (.flow.other_ip // "") != "") then "1" else "0" end)] | @tsv' \
				2>/dev/null)
			rest=$fields
			type=${rest%%"$TAB"*}
			rest=${rest#*"$TAB"}
			digest=${rest%%"$TAB"*}
			has_addrs=${rest#*"$TAB"}
			[ -n "$digest" ] && digest=$(sanitize_digest "$digest")

			case "$type" in
			flow|flow_stats)
				# "flow" carries metadata (ips, ports, protocol/app names)
				# and is sent exactly once, at classification time.
				# "flow_stats" carries only byte/packet counters, sent
				# periodically for flows that are still active.
				[ -z "$digest" ] && continue

				existing='{}'
				is_new=0
				if [ -s "$FLOWS_DIR/$digest.json" ]; then
					existing=$(cat "$FLOWS_DIR/$digest.json")
				elif [ "$type" = "flow" ]; then
					# First sighting via a "flow" event: only track it if
					# it has real addresses. netifyd still emits "flow"
					# for non-IP traffic (ARP, other L2-only frames) with
					# empty local_ip/other_ip, which has nothing
					# meaningful to show on an IP traffic dashboard.
					[ "$has_addrs" = "1" ] || continue
					is_new=1
				else
					# First sighting via "flow_stats" alone: this flow
					# was already active before we (re)connected, so we
					# missed its one-time metadata broadcast and have no
					# IPs/protocol for it. Show it anyway -- it's real
					# traffic -- explicitly marked unclassified rather
					# than left blank (which looked like a bug).
					existing='{"detected_protocol_name":"Unclassified"}'
					is_new=1
				fi

				now=$(date +%s)
				jq -n --argjson existing "$existing" --argjson event "$line" \
					--argjson now "$now" --argjson is_new "$is_new" \
					'$existing * $event.flow * {seen_at: $now}
						* (if $is_new == 1 then {started_at: $now} else {} end)' \
					> "$FLOWS_DIR/$digest.json.tmp" 2>/dev/null &&
					mv "$FLOWS_DIR/$digest.json.tmp" "$FLOWS_DIR/$digest.json"

				if [ "$HISTORY_ENABLED" = "1" ] && [ "$type" = "flow_stats" ]; then
					meta=$(cat "$FLOWS_DIR/$digest.json" 2>/dev/null)
					[ -n "$meta" ] || meta='{}'
					bucket=$((now - (now % HISTORY_ROLLUP_INTERVAL)))
					append_history_rollup "$line" "$meta" "$bucket" false
				fi
				;;
			flow_purge)
				if [ -n "$digest" ]; then
					if [ "$HISTORY_ENABLED" = "1" ] && [ -s "$FLOWS_DIR/$digest.json" ]; then
						meta=$(cat "$FLOWS_DIR/$digest.json")
						now=$(date +%s)
						bucket=$((now - (now % HISTORY_ROLLUP_INTERVAL)))

						append_history_rollup "$line" "$meta" "$bucket" true

						printf '%s' "$line" | jq -c --argjson meta "$meta" \
							--argjson now "$now" --arg digest "$digest" \
							'.flow as $f | {
								digest: $digest,
								started_at: ($meta.started_at // $now),
								ended_at: $now,
								local_ip: $meta.local_ip, local_port: $meta.local_port,
								other_ip: $meta.other_ip, other_port: $meta.other_port,
								protocol: ($meta.detected_protocol_name // "Unclassified"),
								application: $meta.detected_application_name,
								category: ($meta.category.application // $meta.category.domain // $meta.category.protocol // null),
								host_server_name: $meta.host_server_name,
								total_bytes: ($f.total_bytes // 0),
								total_packets: ($f.total_packets // 0)
							}' >> "$HISTORY_PENDING_FLOWS" 2>/dev/null
					fi
					rm -f "$FLOWS_DIR/$digest.json"
				fi
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
