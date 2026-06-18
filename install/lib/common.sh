# shellcheck shell=bash
# install/lib/common.sh — shared helpers for the fleet-platform installer.
#
# INSTALL-TIME RULES (set by Vitaliy 2026-06-18, non-negotiable):
#   1. Every secret/parameter prompt FIRST prints an English description of WHAT
#      it is and WHY it is needed (use prompt_secret / prompt_param — the
#      description argument is MANDATORY).
#   2. All operator-facing install text is in ENGLISH.
#
# Sourced by install.sh and the phase scripts. No side effects on source.

if [ -t 1 ]; then _C_B=$'\033[1m'; _C_D=$'\033[2m'; _C_Y=$'\033[33m'; _C_R=$'\033[0m'
else _C_B=""; _C_D=""; _C_Y=""; _C_R=""; fi

log()  { printf '\n%s==>%s %s\n' "$_C_B" "$_C_R" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s%sWARN:%s %s\n' "$_C_B" "$_C_Y" "$_C_R" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$_C_B" "$_C_R" "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "install.sh must be run as root."; }

# need <cmd> [hint] — assert a command exists (preflight).
need() { command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found${2:+ ($2)}"; }

# _describe NAME "what + why" — the standard described block before any prompt.
# Honors install-time rules #1 (describe) and #2 (English).
_describe() {
  printf '\n  %s%s%s\n' "$_C_B" "$1" "$_C_R"
  # word-wrap the description to ~76 cols for readability
  printf '%s' "$2" | fold -s -w 72 | sed "s/^/  ${_C_D}  /; s/\$/${_C_R}/"
}

# prompt_secret VARNAME "DESCRIPTION" — silently read a secret (no echo) into VARNAME.
# Skips the prompt if VARNAME is already set in the environment (non-interactive runs).
# DESCRIPTION is REQUIRED (rule #1); aborts if omitted.
prompt_secret() {
  local __var="$1" __desc="${2:?prompt_secret: DESCRIPTION is mandatory (install rule #1)}"
  _describe "$__var" "$__desc"
  [ "${DRY_RUN:-0}" = "1" ] && { info "(dry-run — would prompt for this secret)"; return 0; }
  if [ -n "${!__var:-}" ]; then info "(value supplied via environment — not prompting)"; return 0; fi
  local __val=""
  printf '    Enter value (input hidden, not echoed): '
  read -rs __val; echo
  [ -n "$__val" ] || die "$__var: empty value not allowed."
  printf -v "$__var" '%s' "$__val"
}

# prompt_param VARNAME "DESCRIPTION" "DEFAULT" — read a visible parameter with a default.
prompt_param() {
  local __var="$1" __desc="${2:?prompt_param: DESCRIPTION is mandatory (install rule #1)}" __default="${3:-}"
  _describe "$__var" "$__desc"
  [ "${DRY_RUN:-0}" = "1" ] && { info "(dry-run — would prompt; default: ${__default:-none})"; return 0; }
  if [ -n "${!__var:-}" ]; then info "(using value from environment: ${!__var})"; return 0; fi
  local __val=""
  printf '    Value%s: ' "${__default:+ [default: $__default]}"
  read -r __val
  [ -n "$__val" ] || __val="$__default"
  printf -v "$__var" '%s' "$__val"
}

# prompt_secret_optional VARNAME "DESCRIPTION" — like prompt_secret, but an empty
# value is ALLOWED (the operator presses Enter to skip this optional integration).
prompt_secret_optional() {
  local __var="$1" __desc="${2:?prompt_secret_optional: DESCRIPTION is mandatory (install rule #1)}"
  _describe "$__var" "$__desc"
  [ "${DRY_RUN:-0}" = "1" ] && { info "(dry-run — optional secret; would prompt, blank = skip)"; return 0; }
  if [ -n "${!__var:-}" ]; then info "(value supplied via environment)"; return 0; fi
  local __val=""
  printf '    Enter value (hidden), or press Enter to SKIP this integration: '
  read -rs __val; echo
  printf -v "$__var" '%s' "$__val"
}

# run_cmd_stdin VALUE CMD... — run CMD with VALUE fed on stdin (for sub-scripts that
# read a secret via `read -rs`); honors DRY_RUN (prints the command, value hidden).
run_cmd_stdin() {
  local __val="$1"; shift
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would run (secret on stdin): $*"; return 0; fi
  printf '%s\n' "$__val" | "$@"
}

# describe_generated NAME "DESCRIPTION" — announce an auto-generated secret (no prompt),
# still explaining what it is and why (rule #1) so the operator understands what was created.
describe_generated() { _describe "$1" "$2"; info "(auto-generated during install — you are not asked for it)"; }

# confirm "QUESTION" — yes/no gate. Auto-yes when ASSUME_YES=1.
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local __a=""; printf '\n  %s [y/N]: ' "$1"; read -r __a
  case "$__a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# run_cmd CMD... — execute a side-effecting command, or just print it under --dry-run.
run_cmd() {
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would run: $*"; return 0; fi
  "$@"
}

# run_phase NAME FUNC — run a phase unless --phase filtered it out. The phase
# function is ALWAYS called (so descriptions/plan print); its mutations are
# themselves dry-run-guarded via run_cmd / the prompt helpers / DRY_RUN checks.
run_phase() {
  local __name="$1" __fn="$2"
  if [ -n "${ONLY_PHASE:-}" ] && [ "${ONLY_PHASE}" != "$__name" ]; then
    return 0
  fi
  log "PHASE: $__name${DRY_RUN:+ (dry-run)}"
  "$__fn"
}
