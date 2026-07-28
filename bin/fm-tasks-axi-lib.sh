# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# The archive readers below exist because `done_keep` retention moves finished
# tasks out of the live backlog into the configured archive, where `tasks-axi
# show` cannot reach them: it refuses `--file <archive>` while that path is the
# configured archive. Any check that must still recognise a task after retention
# has aged it out reads the archive through these readers instead:
#   fm_tasks_axi_archive_path <home>       -> configured archive path, or 1
#   fm_tasks_axi_archive_show <home> <id>  -> show-shaped record, or 1
# `fm_tasks_axi_archive_show` renders the most recently archived entry for the
# id in the same field shape `tasks-axi show <id> --full` prints, so callers
# parse one format. It emits only the fields the archive preserves - id, title,
# state, kind, repo, and body - because hold metadata is not recoverable from an
# archived entry; a caller that requires `held` must treat its absence as not
# held.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# Print a TOML string value from <config>. <section> is the bare table name the
# key must sit under, or empty for the top-level table. Both double-quoted and
# literal single-quoted strings are accepted: tasks-axi honours either, so a
# value it acts on must never read as absent here.
fm_toml_string() {  # <config> <section> <key>
  awk -v want_section="$2" -v want_key="$3" '
    BEGIN { section = ""; q = sprintf("%c", 39) }
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
      sub(/[[:space:]]*\].*$/, "", section)
      next
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (section != want_section) next
      if (index(line, want_key) != 1) next
      rest = substr(line, length(want_key) + 1)
      if (rest !~ /^[[:space:]]*=/) next
      sub(/^[[:space:]]*=[[:space:]]*/, "", rest)
      if (match(rest, "^\"[^\"]*\"") || match(rest, "^" q "[^" q "]*" q)) {
        print substr(rest, 2, RLENGTH - 2)
        exit
      }
    }
  ' "$1"
}

# Print the archive path <home> archives into, resolved the way tasks-axi
# resolves it: per key from the home's own .tasks.toml first and the captain's
# ~/.tasks-axi/config.toml second, relative to the home. tasks-axi does not walk
# up to a parent config, so a home without either still archives - into the
# tool's own default, `done-archive.md` beside whichever backlog it discovers -
# and that default is reproduced here rather than read as "this home has no
# archive", which would silently refuse every decision the home ever settled.
# Returns 1 only for a non-markdown backend, which has no archive file to read.
fm_tasks_axi_archive_path() {
  local home=$1 backend='' archive='' path='' config candidate base
  for config in "$1/.tasks.toml" "${HOME:-}/.tasks-axi/config.toml"; do
    [ -f "$config" ] || continue
    [ -n "$backend" ] || backend=$(fm_toml_string "$config" '' backend)
    [ -n "$archive" ] || archive=$(fm_toml_string "$config" markdown archive)
    [ -n "$path" ] || path=$(fm_toml_string "$config" markdown path)
  done
  [ -z "$backend" ] || [ "$backend" = markdown ] || return 1
  if [ -z "$archive" ]; then
    base=$path
    if [ -z "$base" ]; then
      base=backlog.md
      for candidate in backlog.md data/backlog.md; do
        if [ -e "$home/$candidate" ]; then
          base=$candidate
          break
        fi
      done
    fi
    case "$base" in
      */*) archive="${base%/*}/done-archive.md" ;;
      *) archive=done-archive.md ;;
    esac
  fi
  case "$archive" in
    /*) printf '%s\n' "$archive" ;;
    *) printf '%s/%s\n' "$home" "$archive" ;;
  esac
}

# Print the most recently archived entry for <id> in <home> as a show-shaped
# record. Returns 1 when the home configures no archive, the archive is absent,
# or no entry carries that id.
fm_tasks_axi_archive_show() {
  local home=$1 id=$2 archive
  archive=$(fm_tasks_axi_archive_path "$home") || return 1
  [ -f "$archive" ] || return 1
  awk -v want="$id" '
    function esc(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else out = out c
      }
      return out
    }
    # Entry header: "- [x] <id> - <title> (repo: <repo>) (kind: <kind>) ...".
    # The checkbox is the only state the archive records; hold metadata is not
    # preserved. The title is whatever is left once the trailing parenthesised
    # metadata groups are peeled off, so a title of its own may contain "(...)".
    /^- \[[ x]\] / {
      collecting = 0
      rest = substr($0, 7)
      sep = index(rest, " - ")
      entry = (sep ? substr(rest, 1, sep - 1) : rest)
      if (entry != want) next
      found = 1
      collecting = 1
      state = (substr($0, 4, 1) == "x") ? "done" : "queued"
      kind = ""
      if (match(rest, /\(kind: [^)]*\)/)) kind = substr(rest, RSTART + 7, RLENGTH - 8)
      repo = ""
      if (match(rest, /\(repo: [^)]*\)/)) repo = substr(rest, RSTART + 7, RLENGTH - 8)
      title = (sep ? substr(rest, sep + 3) : "")
      gsub(/ blocked-by: [^ )]+/, "", title)
      while (match(title, / \((repo|kind|priority|hold-kind|hold):[^)]*\)$/) ||
             match(title, / \((since|done|merged|reported|closed)[[:space:]][^)]*\)$/))
        title = substr(title, 1, RSTART - 1)
      sub(/[[:space:]]+$/, "", title)
      body = ""
      next
    }
    /^## / { collecting = 0; next }
    collecting {
      line = $0
      sub(/^  /, "", line)
      body = body line "\n"
    }
    END {
      if (!found) exit 1
      sub(/\n+$/, "", body)
      printf "task:\n  id: %s\n  title: %s\n  state: %s\n  kind: %s\n  repo: %s\n  body: \"%s\"\n",
        want, title, state, kind, repo, esc(body)
    }
  ' "$archive"
}
