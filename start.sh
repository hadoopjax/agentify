#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="agentify"
PORT="${DASHBOARD_PORT:-4242}"

# Must be run from inside a repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Run this from inside a git repo."
  exit 1
fi

# Need a .env
if [ ! -f .env ]; then
  echo "No .env found. Create one with:"
  echo "  OPENAI_API_KEY=sk-..."
  echo "  ANTHROPIC_API_KEY=sk-ant-..."
  exit 1
fi

# Build if image doesn't exist
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "Building agentify image..."
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

docker run --rm -it \
  -v "$(pwd)":/repo \
  -v ~/.config/gh:/root/.config/gh:ro \
  -v ~/.gitconfig:/root/.gitconfig:ro \
  --env-file .env \
  -p "$PORT":"$PORT" \
  -e DASHBOARD_PORT="$PORT" \
  "$IMAGE" run "$@"
