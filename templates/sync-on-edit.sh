#!/bin/bash
# Agent hook: auto-run sync-agent-config when a file under .agents/ is edited.
# Register in .cursor/hooks.json as afterFileEdit.
#
# Fails open: unexpected errors exit 0 so editing is never blocked.

set -u

input=$(cat)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

command -v jq >/dev/null 2>&1 || exit 0

file_paths=$(
  printf '%s' "$input" | jq -r '
    [
      .file_path?,
      .path?,
      .filePath?,
      .tool_input.file_path?,
      .tool_input.path?,
      .tool_input.filePath?,
      .tool_input.edits[]?.file_path?,
      .tool_input.edits[]?.path?,
      .params.file_path?,
      .params.path?,
      .arguments.file_path?,
      .arguments.path?
    ]
    | map(select(type == "string" and length > 0))
    | unique
    | .[]
  ' 2>/dev/null
) || exit 0

agents_edited=false

while IFS= read -r file_path; do
  [ -n "$file_path" ] || continue

  case "$file_path" in
    /*) absolute_path="$file_path" ;;
    *)  absolute_path="$repo_root/$file_path" ;;
  esac

  # Only trigger for files inside .agents/
  case "$absolute_path" in
    "$repo_root"/.agents/*) agents_edited=true; break ;;
  esac
done <<< "$file_paths"

"$agents_edited" || exit 0

sync_script="$repo_root/bin/sync-agent-config"
[ -x "$sync_script" ] || exit 0

"$sync_script" >/dev/null 2>&1 || true

exit 0
