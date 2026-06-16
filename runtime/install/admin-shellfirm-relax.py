#!/usr/bin/env python3
# admin-shellfirm-relax.py <policy.yaml> <relax|restore>
#
# M7.5 admin tier: an admin bot must be able to read/list other tenants' home
# dirs to moderate/support them (cross-tenant access still flows ONLY through the
# audited host-sudo broker — other homes aren't mounted in the pod). This toggles
# the two pod-side shellfirm boundary rules that would otherwise auto-deny that:
#   boundary:read_other_bot_home   (cat/ls/grep/... /home/<otherbot>)
#   boundary:list_root_home        (cat/ls/grep/... /root)
#
# It does NOT touch the secret-file guards (.ssh keys, */credentials, vault,
# /etc/shadow, rclone, /proc/*/environ) or destructive rules — those stay live
# for admins too. Destructive ops on other homes remain gated by the broker.
#
# Mechanism: comment the two CHECK definitions (so they never match -> no
# auto-deny) and their two `deny:` entries (so no dangling id), with a marker
# prefix so `restore` is exact and idempotent. Safe to run repeatedly.
import sys

PREFIX = "#ADMINRELAX# "
TARGET_IDS = ("boundary:read_other_bot_home", "boundary:list_root_home")


def is_block_boundary(line):
    """True if `line` starts a new check or a top-level key or is blank — i.e.
    it ends the current check-definition block."""
    if line.strip() == "":
        return True
    stripped = line.lstrip()
    if stripped.startswith("- from:"):
        return True
    # a top-level key like `deny:` / `version:` (no leading indent, ends with ':')
    if line[:1] not in (" ", "\t", "#") and ":" in line:
        return True
    return False


def relax(lines):
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        if line.startswith(PREFIX):          # already relaxed -> pass through
            out.append(line); i += 1; continue
        stripped = line.lstrip()
        # (1) a check-definition block
        if stripped.startswith("- from:"):
            block = [line]; j = i + 1
            while j < n and not is_block_boundary(lines[j]):
                block.append(lines[j]); j += 1
            blocktext = "".join(block)
            if any(("id: " + tid) in blocktext for tid in TARGET_IDS):
                block = [b if b.startswith(PREFIX) else PREFIX + b for b in block]
            out.extend(block); i = j; continue
        # (2) a deny-list entry: `  - boundary:read_other_bot_home`
        if any(stripped.rstrip() == "- " + tid for tid in TARGET_IDS):
            out.append(PREFIX + line); i += 1; continue
        out.append(line); i += 1
    return out


def restore(lines):
    return [l[len(PREFIX):] if l.startswith(PREFIX) else l for l in lines]


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("relax", "restore"):
        sys.stderr.write("usage: admin-shellfirm-relax.py <policy.yaml> <relax|restore>\n")
        sys.exit(2)
    path, mode = sys.argv[1], sys.argv[2]
    with open(path) as f:
        lines = f.readlines()
    new = relax(lines) if mode == "relax" else restore(lines)
    if new != lines:
        with open(path, "w") as f:
            f.writelines(new)
        print(f"{mode}: updated {path}")
    else:
        print(f"{mode}: no change (already in target state) {path}")


if __name__ == "__main__":
    main()
