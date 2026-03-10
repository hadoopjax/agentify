#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="agentify"
PORT="${DASHBOARD_PORT:-4242}"

# First arg is the repo path, rest are agentify flags
REPO="${1:-.}"
shift 2>/dev/null || true

REPO="$(cd "$REPO" && pwd)"

if ! git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1; then
  echo "Not a git repo: $REPO"
  echo "Usage: ./start.sh /path/to/repo [--concurrency 5 ...]"
  exit 1
fi

# Check for .env in repo or agentify dir
ENV_FILE=""
if [ -f "$REPO/.env" ]; then
  ENV_FILE="$REPO/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
else
  echo "No .env found in $REPO or $SCRIPT_DIR"
  echo "Create one with:"
  echo "  OPENAI_API_KEY=sk-..."
  echo "  ANTHROPIC_API_KEY=sk-ant-..."
  exit 1
fi

# Build if image doesn't exist
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "Building agentify image..."
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

echo "Starting agentify on $(basename "$REPO")..."

docker run --rm -it \
  -v "$REPO":/repo \
  -v ~/.config/gh:/root/.config/gh:ro \
  -v ~/.gitconfig:/root/.gitconfig:ro \
  --env-file "$ENV_FILE" \
  -p "$PORT":"$PORT" \
  -e DASHBOARD_PORT="$PORT" \
  "$IMAGE" run "$@"
