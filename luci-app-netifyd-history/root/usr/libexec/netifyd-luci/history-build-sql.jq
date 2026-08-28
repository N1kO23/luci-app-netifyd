def esc: gsub("'"; "''");
def sqlval:
  if . == null then "NULL"
  elif type == "number" then tostring
  else "'" + (tostring | esc) + "'"
  end;

def rollup_stmts:
  $rollups
  | group_by([.bucket_start, .protocol, .application, .category])
  | map({
      bucket_start: .[0].bucket_start,
      protocol: .[0].protocol,
      application: .[0].application,
      category: .[0].category,
      bytes: (map(.bytes) | add),
      packets: (map(.packets) | add),
      flows: (map(select(.completed)) | length)
    })
  | map(. as $r |
      [
        {dimension:"protocol", key: $r.protocol},
        {dimension:"application", key: $r.application},
        {dimension:"category", key: $r.category}
      ]
      | .[]
      | select(.key != null)
      | "INSERT INTO rollups (bucket_start,dimension,key,bytes,packets,flows) VALUES (\($r.bucket_start),\(.dimension|sqlval),\(.key|sqlval),\($r.bytes),\($r.packets),\($r.flows)) ON CONFLICT(bucket_start,dimension,key) DO UPDATE SET bytes=bytes+excluded.bytes, packets=packets+excluded.packets, flows=flows+excluded.flows;"
    );

def flow_stmts:
  $flows
  | map(
      "INSERT INTO flows (digest,started_at,ended_at,local_ip,local_port,other_ip,other_port,protocol,application,category,host_server_name,total_bytes,total_packets) VALUES (" +
      ([.digest, .started_at, .ended_at, .local_ip, .local_port, .other_ip, .other_port, .protocol, .application, .category, .host_server_name, .total_bytes, .total_packets] | map(sqlval) | join(",")) +
      ");"
    );

(rollup_stmts + flow_stmts) as $stmts
| if ($stmts | length) > 0 then
    (["BEGIN;"] + $stmts + ["COMMIT;"])[]
  else empty end
