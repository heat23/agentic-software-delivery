#!/usr/bin/env bash
# command-segments.sh
# Shared shell command segmentation helper for PreToolUse guards.
# Splits a command into executable segments separated by ;, &&, ||, and |.

if [[ "${_COMMAND_SEGMENTS_LIB_LOADED:-}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi
_COMMAND_SEGMENTS_LIB_LOADED="true"

_trim_segment_whitespace() {
  local value="${1-}"
  value=$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s' "$value"
}

_emit_command_segment() {
  local raw="${1-}"
  local trimmed
  trimmed=$(_trim_segment_whitespace "$raw")
  if [[ -n "$trimmed" ]]; then
    printf '%s\n' "$trimmed"
  fi
}

# Print one normalized segment per line.
split_shell_command_segments() {
  local command="${1-}"
  local length="${#command}"
  local i=0
  local current=""
  local ch next
  local in_single=0
  local in_double=0
  local escaped=0

  while [[ $i -lt $length ]]; do
    ch="${command:$i:1}"
    next="${command:$((i + 1)):1}"

    if [[ $escaped -eq 1 ]]; then
      current+="$ch"
      escaped=0
      i=$((i + 1))
      continue
    fi

    if [[ $in_single -eq 0 && "$ch" == "\\" ]]; then
      current+="$ch"
      escaped=1
      i=$((i + 1))
      continue
    fi

    if [[ "$ch" == "'" && $in_double -eq 0 ]]; then
      current+="$ch"
      if [[ $in_single -eq 1 ]]; then
        in_single=0
      else
        in_single=1
      fi
      i=$((i + 1))
      continue
    fi

    if [[ "$ch" == '"' && $in_single -eq 0 ]]; then
      current+="$ch"
      if [[ $in_double -eq 1 ]]; then
        in_double=0
      else
        in_double=1
      fi
      i=$((i + 1))
      continue
    fi

    if [[ $in_single -eq 0 && $in_double -eq 0 ]]; then
      if [[ "$ch" == ";" ]]; then
        _emit_command_segment "$current"
        current=""
        i=$((i + 1))
        continue
      fi

      if [[ "$ch" == "&" && "$next" == "&" ]]; then
        _emit_command_segment "$current"
        current=""
        i=$((i + 2))
        continue
      fi

      if [[ "$ch" == "|" && "$next" == "|" ]]; then
        _emit_command_segment "$current"
        current=""
        i=$((i + 2))
        continue
      fi

      if [[ "$ch" == "|" || "$ch" == $'\n' ]]; then
        _emit_command_segment "$current"
        current=""
        i=$((i + 1))
        continue
      fi
    fi

    current+="$ch"
    i=$((i + 1))
  done

  _emit_command_segment "$current"
}

# Returns 0 when any segment matches the supplied regex.
any_command_segment_matches() {
  local command="${1-}"
  local regex="${2-}"
  local segment=""

  while IFS= read -r segment; do
    [[ -z "$segment" ]] && continue
    if printf '%s\n' "$segment" | grep -qE -- "$regex"; then
      return 0
    fi
  done < <(split_shell_command_segments "$command")

  return 1
}
