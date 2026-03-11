#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="agentify"
PORT="${DASHBOARD_PORT:-4242}"
COLIMA_LOG="${HOME}/.colima/_lima/colima/ha.stderr.log"
CONTAINER_CMD=(colima nerdctl --)
AGENT_ENV_PATH=".agentify/agent.env"
ENV_FILE=""
RUN_ARGS=()

ensure_colima_runtime() {
  if ! command -v colima > /dev/null 2>&1; then
    echo "Colima is required. Install it with: brew install colima"
    exit 1
  fi

  echo "Starting Colima..."
  if ! colima start; then
    echo "Colima failed to start."
    if [ -f "$COLIMA_LOG" ]; then
      echo ""
      echo "Recent Colima log:"
      tail -n 20 "$COLIMA_LOG"
    fi
    echo ""
    echo "Try: colima stop --force && colima start"
    exit 1
  fi
}

ensure_colima_runtime

cleanup() {
  [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ] && rm -f "$ENV_FILE"
}

trap cleanup EXIT

append_env_var() {
  local key="$1"
  local source_file="$2"
  local line=""

  if [ -n "${!key:-}" ]; then
    printf '%s=%s\n' "$key" "${!key}" >> "$ENV_FILE"
    return 0
  fi

  if [ -f "$source_file" ]; then
    line=$(grep -E "^${key}=" "$source_file" | tail -n 1 || true)
    if [ -n "$line" ]; then
      local value="${line#*=}"
      if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi
      printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
      return 0
    fi
  fi

  return 1
}

# First arg is the repo path, rest are agentify flags
REPO="${1:-.}"
shift 2>/dev/null || true

REPO="$(cd "$REPO" && pwd)"

if ! GIT_CONFIG_GLOBAL=/dev/null git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1; then
  echo "Not a git repo: $REPO"
  echo "Usage: ./start.sh /path/to/repo [--concurrency 5 ...]"
  exit 1
fi

# Build a dedicated env file for the agent container.
mkdir -p "$REPO/.agentify"
if [ ! -f "$REPO/$AGENT_ENV_PATH" ]; then
  echo "Missing $REPO/$AGENT_ENV_PATH"
  echo "Create it with:"
  echo "  OPENAI_API_KEY=..."
  echo "  ANTHROPIC_API_KEY=..."
  echo "  GH_TOKEN=..."
  exit 1
fi
ENV_FILE="$(mktemp "$REPO/.agentify/agentify-env.XXXXXX")"
if ! append_env_var OPENAI_API_KEY "$REPO/$AGENT_ENV_PATH"; then
  echo "Missing OPENAI_API_KEY in $REPO/$AGENT_ENV_PATH"
  exit 1
fi
if ! append_env_var ANTHROPIC_API_KEY "$REPO/$AGENT_ENV_PATH"; then
  echo "Missing ANTHROPIC_API_KEY in $REPO/$AGENT_ENV_PATH"
  exit 1
fi
if ! append_env_var GH_TOKEN "$REPO/$AGENT_ENV_PATH"; then
  echo "Missing GH_TOKEN in $REPO/$AGENT_ENV_PATH"
  exit 1
fi

# Build if image doesn't exist
if ! "${CONTAINER_CMD[@]}" image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "Building agentify image..."
  "${CONTAINER_CMD[@]}" build -t "$IMAGE" "$SCRIPT_DIR"
fi

echo "Starting agentify on $(basename "$REPO")..."

RUN_ARGS=(
  run --rm
  -v "$REPO":/repo
  --env-file "$ENV_FILE"
  -p "$PORT":"$PORT"
  -e DASHBOARD_PORT="$PORT"
)

if [ -f "$HOME/.gitconfig" ]; then
  RUN_ARGS+=(-v "$HOME/.gitconfig:/root/.gitconfig:ro")
fi

"${CONTAINER_CMD[@]}" "${RUN_ARGS[@]}" "$IMAGE" run "$@"
