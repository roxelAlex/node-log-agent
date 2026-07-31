#!/usr/bin/env bash
# Install or update a protected log-forwarding agent on one node.
# Usage (as root): curl -fsSL <raw-url> | bash
set -Eeuo pipefail

NODE_NAME=""
readonly AGENT_NAME="node-log-agent"
readonly CONFIG_DIR="/etc/node-log-agent"
readonly CONFIG_PATH="${CONFIG_DIR}/vector.yaml"
readonly ENV_PATH="${CONFIG_DIR}/agent.env"
readonly INGEST_URL="${INGEST_URL:-https://cabinet.roxelalex.xyz}"
readonly INGEST_PATH="${INGEST_PATH:-/node-logs/loki/api/v1/push}"

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required." >&2
  exit 1
fi
if ! docker inspect remnanode >/dev/null 2>&1; then
  echo "Container remnanode was not found." >&2
  exit 1
fi

detect_source_log_dir() {
  local source_dir container_dir
  while IFS='|' read -r source_dir container_dir; do
    if [[ -r "$source_dir/current" ]] && docker exec remnanode test -r "$container_dir/current"; then
      printf '%s\n' "$source_dir"
      return 0
    fi
  done < <(docker inspect remnanode --format '{{range .Mounts}}{{printf "%s|%s\\n" .Source .Destination}}{{end}}')
  return 1
}

if ! SOURCE_LOG_DIR="$(detect_source_log_dir)"; then
  echo "Could not find a mounted directory with a readable current log file." >&2
  exit 1
fi
# The script itself may be received through stdin (curl | bash), so prompts
# must use the controlling terminal instead of stdin.
echo "Detected source log directory: ${SOURCE_LOG_DIR}"
read -r -p "Node name: " NODE_NAME </dev/tty
if [[ -z "$NODE_NAME" ]]; then
  echo "Node name cannot be empty." >&2
  exit 1
fi
read -r -p "Ingestion username: " INGEST_USERNAME </dev/tty
if [[ -z "$INGEST_USERNAME" ]]; then
  echo "Username cannot be empty." >&2
  exit 1
fi
read -r -s -p "Ingestion password: " INGEST_PASSWORD </dev/tty
echo
if [[ -z "$INGEST_PASSWORD" ]]; then
  echo "Password cannot be empty." >&2
  exit 1
fi

install -d -m 0700 "$CONFIG_DIR"
umask 077
cat >"$ENV_PATH" <<EOF
NODE_NAME=${NODE_NAME}
INGEST_URL=${INGEST_URL}
INGEST_PATH=${INGEST_PATH}
INGEST_USERNAME=${INGEST_USERNAME}
INGEST_PASSWORD=${INGEST_PASSWORD}
EOF
chmod 0600 "$ENV_PATH"

cat >"$CONFIG_PATH" <<'EOF'
sources:
  node_current:
    type: file
    include:
      - /var/log/source/current
    read_from: end
transforms:
  label_records:
    type: remap
    inputs: [node_current]
    source: |
      .job = "connections"
      .node = get_env_var!("NODE_NAME")
      .stream = "access"
sinks:
  ingest:
    type: loki
    inputs: [label_records]
    endpoint: "${INGEST_URL}"
    path: "${INGEST_PATH}"
    auth:
      strategy: basic
      user: "${INGEST_USERNAME}"
      password: "${INGEST_PASSWORD}"
    encoding:
      codec: text
    labels:
      job: "{{ job }}"
      node: "{{ node }}"
      stream: "{{ stream }}"
EOF
chmod 0600 "$CONFIG_PATH"

docker pull timberio/vector:0.39.0-alpine
docker rm -f "$AGENT_NAME" >/dev/null 2>&1 || true
docker run -d --name "$AGENT_NAME" --restart unless-stopped \
  --env-file "$ENV_PATH" \
  -v "$CONFIG_PATH:/etc/vector/vector.yaml:ro" \
  -v "$SOURCE_LOG_DIR:/var/log/source:ro" \
  timberio/vector:0.39.0-alpine \
  --config /etc/vector/vector.yaml --require-healthy

sleep 2
if ! docker ps --format '{{.Names}}' | grep -qx "$AGENT_NAME"; then
  echo "The agent did not stay running. Recent logs:" >&2
  docker logs --tail=80 "$AGENT_NAME" >&2 || true
  exit 1
fi
echo "Log agent is running for node ${NODE_NAME}."
echo "Check it with: docker logs --tail=50 ${AGENT_NAME}"
