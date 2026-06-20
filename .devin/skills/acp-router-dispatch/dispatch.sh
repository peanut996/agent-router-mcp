#!/usr/bin/env bash
set -euo pipefail

# acp-router-dispatch: Create a worktree, dispatch an agent, collect results.
# Usage: dispatch.sh --repo <path> --prompt <text> [--branch <branch>] [--agent <id>] [--cleanup]

REPO=""
BRANCH=""
PROMPT=""
AGENT=""
TIMEOUT_SEC=3600
PERMISSION_PROFILE="bypassPermissions"
CLEANUP=false
STREAM=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --agent) AGENT="$2"; shift 2;;
    --timeout-sec) TIMEOUT_SEC="$2"; shift 2;;
    --permission-profile) PERMISSION_PROFILE="$2"; shift 2;;
    --cleanup) CLEANUP=true; shift;;
    --no-stream) STREAM=false; shift;;
    --help|-h)
      echo "Usage: dispatch.sh --repo <path> --prompt <text> [--branch <branch>] [--agent <id>] [--cleanup]"
      echo ""
      echo "Options:"
      echo "  --repo <path>              Git repo path (required)"
      echo "  --prompt <text>            Task prompt (required)"
      echo "  --branch <branch>          Branch to create worktree from (default: current)"
      echo "  --agent <id>               Agent id (default: auto-select)"
      echo "  --timeout-sec <n>          Timeout in seconds (default: 3600)"
      echo "  --permission-profile <p>   plan | acceptEdits | bypassPermissions (default: bypassPermissions)"
      echo "  --cleanup                  Remove worktree on success"
      echo "  --no-stream                Don't stream events to stderr"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

if [[ -z "$REPO" || -z "$PROMPT" ]]; then
  echo "Error: --repo and --prompt are required" >&2
  exit 1
fi

REPO_ABS="$(cd "$REPO" && pwd)"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(cd "$REPO_ABS" && git rev-parse --abbrev-ref HEAD)"
fi

# Create worktree
WT_DIR="/tmp/acp-router-wt-$(date +%s)-$$"
BASE_BRANCH="acp-router-base-$(date +%s)-$$"

echo "==> Creating worktree at $WT_DIR (branch: $BRANCH)" >&2
cd "$REPO_ABS"
git worktree add -b "$BASE_BRANCH" "$WT_DIR" "$BRANCH" >&2

# Run agent
echo "==> Dispatching agent" >&2
STREAM_FLAG=""
if [[ "$STREAM" == "true" ]]; then
  STREAM_FLAG="--stream"
fi

AGENT_FLAG=""
if [[ -n "$AGENT" ]]; then
  AGENT_FLAG="--agent $AGENT"
fi

RESULT=$(acp-router-cli run \
  --worktree "$WT_DIR" \
  --prompt "$PROMPT" \
  $AGENT_FLAG \
  --timeout-sec "$TIMEOUT_SEC" \
  --permission-profile "$PERMISSION_PROFILE" \
  $STREAM_FLAG 2>&1 || true)

echo "$RESULT"

# Extract job status
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")

if [[ "$STATUS" == "completed" ]]; then
  echo "==> Agent completed successfully" >&2
  echo "==> Worktree: $WT_DIR" >&2
  echo "==> Review changes: cd $WT_DIR && git diff" >&2
  if [[ "$CLEANUP" == "true" ]]; then
    echo "==> Cleaning up worktree" >&2
    cd "$REPO_ABS"
    git worktree remove "$WT_DIR" --force
    git branch -D "$BASE_BRANCH" 2>/dev/null || true
  fi
else
  echo "==> Agent status: $STATUS" >&2
  echo "==> Worktree kept for inspection: $WT_DIR" >&2
  echo "==> Job log: ~/.acp-router/logs/" >&2
fi
