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
detect_source_log_dir() {
  local container_name="$1" source_dir container_dir
  while IFS='|' read -r source_dir container_dir; do
    if [[ -r "$source_dir/current" ]] && docker exec "$container_name" test -r "$container_dir/current"; then
      printf '%s\n' "$source_dir"
      return 0
    fi
  done < <(docker inspect "$container_name" --format '{{range .Mounts}}{{printf "%s|%s\n" .Source .Destination}}{{end}}')
  return 1
}

detect_container_log_file() {
  local container_name="$1"
  docker exec "$container_name" sh -c '
    for candidate in /var/log/current /var/log/*/current /var/log/*/*/current; do
      if [ -f "$candidate" ] && [ -r "$candidate" ]; then
        printf "%s\\n" "$candidate"
        exit 0
      fi
    done
    exit 1
  '
}

find_target_container() {
  local container_name container_log_file compose_files compose_service compose_project
  while IFS= read -r container_name; do
    container_log_file="$(detect_container_log_file "$container_name" 2>/dev/null)" || continue
    compose_files="$(docker inspect "$container_name" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')"
    compose_service="$(docker inspect "$container_name" --format '{{ index .Config.Labels "com.docker.compose.service" }}')"
    compose_project="$(docker inspect "$container_name" --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
    if [[ -n "$compose_files" && "$compose_files" != '<no value>' && -n "$compose_service" && "$compose_service" != '<no value>' && -n "$compose_project" && "$compose_project" != '<no value>' ]]; then
      printf '%s|%s|%s|%s|%s\n' "$container_name" "$container_log_file" "$compose_files" "$compose_service" "$compose_project"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}')
  return 1
}

ensure_host_log_mount() {
  local container_name="$1" container_log_file="$2" compose_files="$3" compose_service="$4" compose_project="$5"
  local -a compose_file_list compose_args=()
  local compose_override compose_dir host_log_dir yq_expression
  IFS=',' read -r -a compose_file_list <<< "$compose_files"
  compose_override="${compose_file_list[${#compose_file_list[@]} - 1]}"
  compose_dir="$(dirname "$compose_override")"
  host_log_dir="/opt/node-log-agent/${compose_service}-logs"
  install -d -m 0755 "$host_log_dir"
  cp -- "$compose_override" "${compose_override}.node-log-agent.bak"
  yq_expression=".services.\"${compose_service}\".volumes = ((.services.\"${compose_service}\".volumes // []) + [\"${host_log_dir}:$(dirname "$container_log_file")\"] | unique)"
  echo "Adding the host log mount and recreating service ${compose_service}." >&2
  docker run --rm -v "${compose_dir}:/work" -w /work mikefarah/yq:4.44.3 -i "$yq_expression" "$(basename "$compose_override")" >&2
  for compose_file in "${compose_file_list[@]}"; do
    compose_args+=(-f "$compose_file")
  done
  docker compose -p "$compose_project" "${compose_args[@]}" up -d --force-recreate "$compose_service" >&2
  printf '%s\n' "$host_log_dir"
}

if ! TARGET="$(find_target_container)"; then
  echo "Could not find a running Compose container with a readable current log file." >&2
  exit 1
fi
IFS='|' read -r TARGET_CONTAINER CONTAINER_LOG_FILE COMPOSE_FILES COMPOSE_SERVICE COMPOSE_PROJECT <<< "$TARGET"
if SOURCE_LOG_DIR="$(detect_source_log_dir "$TARGET_CONTAINER")"; then
  echo "Detected source log directory: ${SOURCE_LOG_DIR}"
else
  SOURCE_LOG_DIR="$(ensure_host_log_mount "$TARGET_CONTAINER" "$CONTAINER_LOG_FILE" "$COMPOSE_FILES" "$COMPOSE_SERVICE" "$COMPOSE_PROJECT")"
  for _ in {1..20}; do
    [[ -r "$SOURCE_LOG_DIR/current" ]] && break
    sleep 1
  done
  if [[ ! -r "$SOURCE_LOG_DIR/current" ]]; then
    echo "The recreated service did not create a readable current log file." >&2
    exit 1
  fi
fi
LOG_FILE="/var/log/source/current"
# The script itself may be received through stdin (curl | bash), so prompts
# must use the controlling terminal instead of stdin.
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
LOG_FILE=${LOG_FILE}
EOF
chmod 0600 "$ENV_PATH"

cat >"$CONFIG_PATH" <<'EOF'
sources:
  node_current:
    type: file
    include:
      - "${LOG_FILE}"
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
  --config /etc/vector/vector.yaml --require-healthy true

sleep 2
if ! docker ps --format '{{.Names}}' | grep -qx "$AGENT_NAME"; then
  echo "The agent did not stay running. Recent logs:" >&2
  docker logs --tail=80 "$AGENT_NAME" >&2 || true
  exit 1
fi
echo "Log agent is running for node ${NODE_NAME}."
echo "Check it with: docker logs --tail=50 ${AGENT_NAME}"
