#!/usr/bin/env bash
# lib/worktree-command.sh
# Shared parsing helpers for git worktree add/remove command segments.

extract_git_worktree_command() {
  local segment="${1:-}"
  local default_cwd="${2:-$PWD}"

  python3 - "$segment" "$default_cwd" <<'PY'
import os
import re
import shlex
import sys

segment = sys.argv[1]
default_cwd = os.path.abspath(sys.argv[2] or os.getcwd())

assign_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")


def resolve(base, value):
    if not value:
        return ""
    if os.path.isabs(value):
        return os.path.abspath(value)
    return os.path.abspath(os.path.join(base, value))


try:
    tokens = shlex.split(segment)
except Exception:
    sys.exit(1)

if not tokens:
    sys.exit(1)

i = 0
while i < len(tokens) and assign_re.match(tokens[i]):
    i += 1

if i < len(tokens) and tokens[i] == "command":
    i += 1

if i >= len(tokens) or os.path.basename(tokens[i]) != "git":
    sys.exit(1)

i += 1
git_cwd = default_cwd
subcommand = ""
rest = []

while i < len(tokens):
    token = tokens[i]
    if token == "-C" and i + 1 < len(tokens):
      git_cwd = resolve(default_cwd, tokens[i + 1])
      i += 2
      continue
    if token.startswith("-C") and token != "-C":
      value = token[2:]
      if value.startswith("="):
        value = value[1:]
      if value:
        git_cwd = resolve(default_cwd, value)
        i += 1
        continue
    if token == "worktree" and i + 1 < len(tokens) and tokens[i + 1] in ("add", "remove"):
        subcommand = tokens[i + 1]
        rest = tokens[i + 2:]
        break
    i += 1

if not subcommand:
    sys.exit(1)

path = ""
cursor = 0

if subcommand == "add":
    flags_with_arg = {"-b", "-B", "--orphan", "--reason"}
    flags_no_arg = {
        "-d",
        "-f",
        "-q",
        "--checkout",
        "--detach",
        "--force",
        "--guess-remote",
        "--lock",
        "--no-track",
        "--quiet",
        "--relative-paths",
        "--track",
    }
elif subcommand == "remove":
    flags_with_arg = {"--expire"}
    flags_no_arg = {"-f", "-q", "--dry-run", "--force", "--quiet", "--verbose"}
else:
    flags_with_arg = set()
    flags_no_arg = set()

while cursor < len(rest):
    token = rest[cursor]
    if token in flags_with_arg:
        cursor += 2
        continue
    if any(token.startswith(flag + "=") for flag in flags_with_arg):
        cursor += 1
        continue
    if token in flags_no_arg:
        cursor += 1
        continue
    if token.startswith("--"):
        cursor += 1
        continue
    path = resolve(git_cwd, token)
    break

print(f"{subcommand}\t{os.path.abspath(git_cwd)}\t{path}")
PY
}

extract_git_worktree_path() {
  local parsed=""
  local path=""

  parsed=$(extract_git_worktree_command "${1:-}" "${2:-$PWD}" 2>/dev/null) || return 1
  IFS=$'\t' read -r _ _ path <<< "$parsed"
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

worktree_common_repo_root() {
  local wt_path="${1:-}"
  local common_dir=""

  [ -n "$wt_path" ] || return 1
  common_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
  [ -n "$common_dir" ] || return 1
  (
    cd "$common_dir/.." >/dev/null 2>&1 && pwd
  )
}
