// @fleet/audit-collector — append-only, tamper-resistant audit sink.
//
// M1 scope (built at M1.3): listen on a unix socket (/run/audit/collector.sock),
// write each event as a hash-chained record ({ts,user_id,kind,actor,payload,
// prev_hash,hash}) to append-only WORM files in /srv/audit (chattr +a), and
// index it in audit_index. Tenants/containers get write-only socket access and
// cannot read or mutate the store.
//
// Real implementation is filled in at M1.3. This placeholder keeps the
// workspace graph valid before that step.

export const PLACEHOLDER = "fleet-audit-collector M1.3 not yet implemented";
