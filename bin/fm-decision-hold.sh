#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded. A decision counts as durable while it is
# actively held, and after it has been resolved for as long as its resolution
# record survives - in the live backlog, or in the configured archive once
# `done_keep` retention has moved it there. Reaching into the archive never
# lowers the bar: an archived entry passes only when it carries the same
# resolution record the live check demands, answered for the origin asking.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the origin, captain decision and routed identities into the hold body,
# clears those dependency edges, and only then marks the hold Done. A failure
# before the final step leaves the captain hold open. A hold retention has already
# archived is restored into the live backlog first, so an answer stays recordable
# for as long as the decision matters rather than only until `done_keep` expires.
# Every precondition is checked before that restore, so a refused `resolve` writes
# nothing and leaves the gate's verdict exactly where it found it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

# hold_record <id>: the live backlog record, or the archived one once backlog
# retention has aged the task out of `tasks-axi show`. A decision stays durable
# for the whole life of the work it gated, which outlives `done_keep`, so a
# lookup that reads only the live backlog reports a long-resolved decision as
# absent and refuses cleanup forever. The live record wins whenever both exist,
# because it is the current one.
hold_record() {  # <id>
  local id=$1 show
  if show=$(task_show "$id"); then
    printf '%s\n' "$show"
    return 0
  fi
  fm_tasks_axi_archive_show "$FM_HOME" "$id"
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A record's body without the quotes tasks-axi wraps it in. The value stays the
# single escaped line tasks-axi prints, so \n is two characters here.
show_body() {  # <record>
  local body
  body=$(show_field "$1" body)
  body=${body#\"}
  printf '%s' "${body%\"}"
}

# The structured header this script writes above the captain's own prose. Field
# lookups stay inside it so decision text that happens to start a line with a
# field label is never read as one of this script's own fields.
body_header() {  # <body>
  local body=$1
  case "$body" in
    *'\n\nCaptain decision:'*) printf '%s' "${body%%\\n\\nCaptain decision:*}" ;;
    *) printf '%s' "$body" ;;
  esac
}

body_field() {  # <body> <label>
  local header rest
  header=$(body_header "$1")
  case "$header" in
    "$2: "*) rest=${header#"$2: "} ;;
    *"\\n$2: "*) rest=${header#*"\\n$2: "} ;;
    *) return 1 ;;
  esac
  printf '%s' "${rest%%\\n*}"
}

# A hold identity is composed as <origin-id>-decision-<decision-key>, which two
# different investigations can compose to the same string, so identity alone
# does not prove a record answers for the origin asking. Provenance is matched
# whenever the record names one and is never required: every record written
# before this script recorded origins names none, and refusing those would make
# each already-resolved decision start refusing again.
origin_matches() {  # <body> <origin-id>
  local recorded
  recorded=$(body_field "$1" Origin) || return 0
  [ -n "$2" ] || return 0
  [ "$recorded" = "$2" ]
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from the $FM_HOME backlog"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

# The durable resolution shape: closed as a captain decision, carrying the
# resolution record this script writes on the way to Done, answered for the
# origin asking. Presence alone is never enough, in the live backlog or in the
# archive - a captain hold closed by any other route keeps the unanswered body
# it was created with, and a decision that was never answered must still refuse.
resolved_record() {  # <record> [origin-id]
  local record=$1 origin=${2:-} state kind body
  state=$(show_field "$record" state)
  kind=$(show_field "$record" kind)
  body=$(show_body "$record")
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) : ;;
    *) return 1 ;;
  esac
  origin_matches "$body" "$origin"
}

verify_hold_resolved() {  # <hold-id> <origin-id>
  local record
  record=$(hold_record "$1") || return 1
  resolved_record "$record" "$2"
}

verify_hold_durable() {  # <hold-id> <origin-id>
  local id=$1 origin=$2 record state held kind hold_kind
  record=$(hold_record "$id") \
    || fail "captain decision $id is absent from the $FM_HOME backlog and its archive"
  state=$(show_field "$record" state)
  held=$(show_field "$record" held)
  kind=$(show_field "$record" kind)
  hold_kind=$(show_field "$record" hold_kind)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    if origin_matches "$(show_body "$record")" "$origin"; then
      return 0
    fi
    fail "captain decision $id is held for another origin"
  fi
  if resolved_record "$record" "$origin"; then
    return 0
  fi
  if resolved_record "$record"; then
    fail "captain decision $id carries a resolution answered for another origin"
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 recorded_digest recorded_routes
  case "$hold_body" in
    'Resolution recorded by fm-decision-hold.'*) : ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$hold_body" in
    *'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=$(body_field "$hold_body" 'Decision digest') \
    || fail "captain hold $id has an invalid retry identity record"
  recorded_routes=$(body_field "$hold_body" 'Routed identities') \
    || fail "captain hold $id has an invalid retry identity record"
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

# The durable dependency record. `blocked_by` is the live view of what still
# blocks a task, so it drops an edge the moment its blocker closes and reads as
# absent for a hold retention has already archived. `deps` keeps every recorded
# edge whatever state its blocker is in, and tasks-axi quotes a multi-entry
# value as "blocked-by:a,blocked-by:b", so strip the quotes before matching on
# comma boundaries.
routed_edge_exists() {  # <routed-task-record> <hold-id>
  local deps
  deps=$(show_field "$1" deps | tr -d '[:space:]')
  deps=${deps#\"}
  deps=${deps%\"}
  case ",$deps," in
    *",blocked-by:$2,"*) return 0 ;;
  esac
  return 1
}

# Everything about an archived hold that has to hold before it may be restored.
# Read-only, so `resolve` can clear every precondition while the hold is still
# archived and reach its first write knowing the write will not have to be undone.
verify_archived_hold_restorable() {  # <origin-id> <hold-id> <record>
  local origin=$1 id=$2 record=$3
  [ "$(show_field "$record" kind)" = captain ] \
    || fail "archived backlog item $id is not kind captain"
  origin_matches "$(show_body "$record")" "$origin" \
    || fail "archived captain hold $id was filed for another origin"
  [ -n "$(show_field "$record" title)" ] \
    || fail "archived captain hold $id has no title to restore"
}

# Bring an archived captain hold back into the live backlog so the captain's
# answer can still be recorded against it. Retention archives a hold once it is
# closed and tasks-axi cannot write into the archive, so an answer to a decision
# that has aged out would otherwise be permanently unrecordable - and re-running
# `hold` cannot recover it either once the origin's own state is gone. The
# restored item keeps the archived title and repo and gets the same unanswered
# body a fresh hold gets, because the archived body is either that same
# unanswered text or another investigation's answer, which is never inherited.
restore_archived_hold() {  # <origin-id> <decision-key> <hold-id> <record>
  local origin=$1 key=$2 id=$3 record=$4 title repo body
  title=$(show_field "$record" title)
  repo=$(show_field "$record" repo)
  [ -n "$repo" ] || repo=firstmate
  body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
  tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
    || fail "could not restore archived captain hold $id"
  tasks_axi hold "$id" --reason "captain decision restored from the archive" --kind captain >/dev/null \
    || fail "could not reactivate restored captain hold $id"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")" "$origin"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")" "$origin"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")" "$origin"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0 archived=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id" "$origin"; then
    hold_show=$(hold_record "$id")
    hold_body=$(show_body "$hold_show")
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  if hold_show=$(task_show "$id"); then
    verify_hold_active "$id"
  else
    archived=1
    hold_show=$(fm_tasks_axi_archive_show "$FM_HOME" "$id") \
      || fail "captain hold $id is absent from the $FM_HOME backlog and its archive"
    verify_archived_hold_restorable "$origin" "$id" "$hold_show"
  fi
  hold_body=$(show_body "$hold_show")
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      origin_matches "$hold_body" "$origin" \
        || fail "captain hold $id records a resolution answered for another origin"
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    if ! routed_edge_exists "$show" "$id"; then
      case "$hold_body" in
        *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
        *) fail "routed task $dep is not durably blocked by $id" ;;
      esac
    fi
  done

  # Every precondition has been checked, so the first write below is also the
  # first change a caller can observe: a refused resolution leaves the backlog,
  # the archive, and therefore the gate's verdict exactly as it found them.
  if [ "$archived" = 1 ]; then
    restore_archived_hold "$origin" "$key" "$id" "$hold_show"
    verify_hold_active "$id"
  fi

  body=$(printf 'Resolution recorded by fm-decision-hold.\nOrigin: %s\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$origin" "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" "$origin" \
    || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
