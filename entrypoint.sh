#!/bin/bash
set -eo pipefail

START_BOOT_TIME=$(date +%s)
export GIT_TERMINAL_PROMPT=0

# ==============================================================================
# Global Logging & Paths
# ==============================================================================
LOG_DIR="${LOG_DIR:-/var/log/runner}"
mkdir -p "${LOG_DIR}"

exec > >(tee -a "${LOG_DIR}/entrypoint.log") 2>&1

echo "===================================================="
echo "[Startup] Bootstrapping Fish Audio S2 Pro Pipeline"
echo "===================================================="

# Diagnostic check: verify worker.js is valid JavaScript
if head -n 3 /app/worker.js 2>/dev/null | grep -qi "pipefail\|bash\|bin"; then
    echo "[CRITICAL ERROR] /app/worker.js contains shell code! Aborting."
    sleep 3600
    exit 1
fi

# ==============================================================================
# Pre-Flight Environment Validation
# ==============================================================================
REQUIRED_VARS=(
    "API_BASE_URL"
    "WORKER_API_SECRET"
    "JOB_TYPE"
    "MODEL"
    "POLL_INTERVAL_SECONDS"
    "MAX_EMPTY_POLLS"
    "R2_ACCOUNT_ID"
    "R2_ACCESS_KEY_ID"
    "R2_SECRET_ACCESS_KEY"
    "R2_BUCKET_NAME"
    "R2_CDN_URL"
)

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING+=("$var")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[FATAL] Missing required environment variables:"
    for m in "${MISSING[@]}"; do
        echo "  - $m"
    done
    exit 1
fi

# ==============================================================================
# 1. Platform & Hardware Discovery
# ==============================================================================
discover_lium_pod_id() {
    [ -z "$LIUM_API_KEY" ] && return 1
    local lium_base="${LIUM_BASE_URL:-https://lium.io/api}"

    python3 -c '
import json, urllib.request, socket, sys
api_key, base_url, host = sys.argv[1], sys.argv[2], socket.gethostname().strip().lower()
req = urllib.request.Request(f"{base_url}/pods", headers={"X-API-Key": api_key, "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode())
        pods = data if isinstance(data, list) else data.get("data", data.get("pods", []))
        for p in pods:
            containers = p.get("executor", {}).get("specs", {}).get("docker", {}).get("containers", [])
            if any(c.get("container_id", "").lower().startswith(host) for c in containers):
                sys.stdout.write(str(p.get("id") or p.get("uuid") or p.get("pod_id", "")))
                sys.exit(0)
        if len(pods) == 1:
            sys.stdout.write(str(pods[0].get("id") or pods[0].get("uuid") or pods[0].get("pod_id", "")))
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$LIUM_API_KEY" "$lium_base"
}

is_hyperstack() {
    curl -s --connect-timeout 1 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | grep -qi "nexgen\|hyperstack" && return 0
    cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null | grep -qi "nexgen\|hyperstack" && return 0
    [ -d "/etc/hyperstack" ] || [ -f "/var/log/hyperstack-init.log" ] || [ -n "$HYPERSTACK_API_KEY" ] && return 0
    return 1
}

if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$VAST_CONTAINERLABEL" ] || [ -n "$CONTAINER_ID" ] || [ -n "$VAST_TCP_PORT_22" ]; then
    export RUNNER_PLATFORM="vastai"
elif [ -n "$RUNPOD_POD_ID" ]; then
    export RUNNER_PLATFORM="runpod"
elif LIUM_DISCOVERED=$(discover_lium_pod_id); then
    export LIUM_POD_ID="$LIUM_DISCOVERED"
    export RUNNER_PLATFORM="lium"
    echo "[Platform] Verified Lium Pod ID: ${LIUM_POD_ID}"
elif is_hyperstack; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="generic"
fi

if command -v nvidia-smi &> /dev/null; then
    export RUNNER_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)
    export RUNNER_GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | xargs)
    export RUNNER_GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1 | tr -d '[:space:]' | xargs)
else
    export RUNNER_GPU_NAME="None"
    export RUNNER_GPU_COUNT="1"
    export RUNNER_GPU_VRAM="0"
fi

NUM_GPUS="${RUNNER_GPU_COUNT:-1}"
[ "$NUM_GPUS" -lt 1 ] && NUM_GPUS=1

# Strict single worker instance plan
PLAN_JSON=$(node -e '
const maxAllowed = parseInt(process.env.MAX_INSTANCES || "1", 10);
let plan = [];
for (let i = 1; i <= maxAllowed; i++) {
    plan.push({
        instance: i,
        gpu: 0,
        port: 8080 + i - 1
    });
}
console.log(JSON.stringify(plan));
')

TOTAL_INSTANCES=$(echo "$PLAN_JSON" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf8')).length);")
MACHINE_ID=$(hostname)
HYPERSTACK_VM_NAME="${VM_NAME:-${MACHINE_ID}}"

echo "===================================================="
echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($NUM_GPUS detected)"
echo "[Hardware] Scaling  : Planned ${TOTAL_INSTANCES} TTS worker(s)"
echo "===================================================="

# ==============================================================================
# 2. Session Initialization (/v1/worker/on)
# ==============================================================================
echo "[Billing] Registering worker startup session via /v1/worker/on..."
SESSION_PAYLOAD=$(cat <<EOF
{
  "machine_id": "${MACHINE_ID}",
  "provider": "${RUNNER_PLATFORM}",
  "gpu_name": "${RUNNER_GPU_NAME}",
  "gpu_count": ${NUM_GPUS},
  "gpu_vram": "${RUNNER_GPU_VRAM}",
  "instances": ${TOTAL_INSTANCES}
}
EOF
)

SESSION_RESPONSE=$(curl -s -S -X POST "${API_BASE_URL}/v1/worker/on" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${SESSION_PAYLOAD}" || echo '{"success":false}')

export WORKER_SESSION_ID=$(echo "$SESSION_RESPONSE" | node -e "
    const fs = require('fs');
    try {
        const res = JSON.parse(fs.readFileSync(0, 'utf-8'));
        if (res.success && res.session_id) process.stdout.write(res.session_id);
    } catch (_) {}
")

if [ -z "$WORKER_SESSION_ID" ]; then
    echo "[FATAL] Failed to obtain valid session ID from /v1/worker/on. Aborting."
    exit 1
fi
echo "[Billing] Active Worker Session ID: ${WORKER_SESSION_ID}"

# ==============================================================================
# 3. Weights & Storage Setup (Fish Audio S2 Pro)
# ==============================================================================
PERSISTENT_DIR="${PERSISTENT_STORAGE_DIR:-/workspace}"
CHECKPOINT_DIR="${PERSISTENT_DIR}/checkpoints/s2-pro"
mkdir -p "${CHECKPOINT_DIR}" /tmp

download_checkpoint() {
    if [ -f "${CHECKPOINT_DIR}/codec.pth" ] && ([ -f "${CHECKPOINT_DIR}/model-00001-of-00002.safetensors" ] || [ -f "${CHECKPOINT_DIR}/model.safetensors" ]); then
        echo "[Storage] S2 Pro weights found in ${CHECKPOINT_DIR}. Skipping download."
        return 0
    fi

    echo "[Storage] Downloading Fish Audio S2 Pro weights via Python snapshot_download..."
    uv run python -c "
from huggingface_hub import snapshot_download
import os

token = os.getenv('HF_TOKEN') or None
snapshot_download(
    repo_id='fishaudio/s2-pro',
    local_dir='${CHECKPOINT_DIR}',
    token=token
)
"
    echo "[Storage] Download completed successfully."
}

download_checkpoint
export FISH_CHECKPOINT_DIR="${CHECKPOINT_DIR}"

rm -f /tmp/worker_stats_*.json /tmp/worker_stats.json /tmp/node_worker_pids.txt

# ==============================================================================
# 4. Spawning TTS Backends and Worker Orchestrators
# ==============================================================================
pkill -f "tools/api_server.py" || true
cd /app

cleanup_processes() {
    echo "[Cleanup] Stopping child workers..."
    pkill -P $$ || true
    pkill -f "tools/api_server.py" || true
    pkill -f "node worker.js" || true
}
trap cleanup_processes EXIT SIGINT SIGTERM

echo "[Startup] Spawning official Fish Speech API server backend(s)..."
echo "$PLAN_JSON" | node -e '
const fs = require("fs");
const cp = require("child_process");
const logDir = process.env.LOG_DIR || "/var/log/runner";
const ckptDir = process.env.FISH_CHECKPOINT_DIR || "/workspace/checkpoints/s2-pro";
const plan = JSON.parse(fs.readFileSync(0, "utf-8"));

plan.forEach(item => {
    console.log(`[Startup] Spawning API server ${item.instance} on GPU ${item.gpu} (Port ${item.port})`);
    const backendEnv = Object.assign({}, process.env, {
        CUDA_VISIBLE_DEVICES: String(item.gpu)
    });
    const logOut = fs.openSync(`${logDir}/tts_backend_${item.instance}.log`, "a");
    const child = cp.spawn("uv", [
        "run", "tools/api_server.py",
        "--listen", `0.0.0.0:${item.port}`,
        "--llama-checkpoint-path", ckptDir,
        "--decoder-checkpoint-path", `${ckptDir}/codec.pth`,
        "--decoder-config-name", "modded_dac_vq"
    ], {
        env: backendEnv,
        detached: true,
        stdio: ["ignore", logOut, logOut]
    });
    child.unref();
});
'

echo "[Startup] Waiting for backend /v1/health checks..."
PORTS=$(echo "$PLAN_JSON" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf8')).map(x => x.port).join(' '));")
for PORT in $PORTS; do
    echo "[HealthCheck] Polling port ${PORT}..."
    until curl -s "http://127.0.0.1:${PORT}/v1/health" | grep -q "ok"; do
        sleep 2
    done
    echo "[HealthCheck] Port ${PORT} is UP and ready."
done

echo "[Startup] Launching Node.js workers..."
WORKER_PIDS=()
for row in $(echo "$PLAN_JSON" | node -e "const fs=require('fs'); JSON.parse(fs.readFileSync(0,'utf8')).forEach(x => console.log(x.instance + ':' + x.port));"); do
    IDX="${row%%:*}"
    PORT="${row##*:}"
    echo "[Worker] Starting worker_${IDX} linked to port ${PORT}..."
    
    WORKER_SUFFIX="worker_${IDX}" \
    TTS_PORT="${PORT}" \
    WORKER_SESSION_ID="${WORKER_SESSION_ID}" \
    node worker.js &
    
    WORKER_PIDS+=($!)
    echo $! >> /tmp/node_worker_pids.txt
done

echo "[Startup] All workers active. Awaiting job drain..."

WORKER_EXIT_CODE=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" || WORKER_EXIT_CODE=$?
done

# ==============================================================================
# 5. Metrics Aggregation & Session Teardown
# ==============================================================================
UPTIME_SEC=$(( $(date +%s) - START_BOOT_TIME ))

echo "[Billing] Finalizing session with /v1/worker/off..."
STATS_DATA=$(node -e "
    const fs = require('fs');
    const path = require('path');
    let jobs = 0, duration = 0;
    try {
        const files = fs.readdirSync('/tmp').filter(f => f.startsWith('worker_stats_') && f.endsWith('.json'));
        for (const f of files) {
            try {
                const data = JSON.parse(fs.readFileSync(path.join('/tmp', f), 'utf8'));
                jobs += data.jobs_processed || 0;
                duration += data.total_generation_time_sec || 0;
            } catch (_) {}
        }
    } catch (_) {}
    console.log(JSON.stringify({ jobs, duration: Math.round(duration) }));
")

JOBS_PROCESSED=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf-8')).jobs || 0);")
TOTAL_GEN_TIME=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf-8')).duration || 0);")

OFF_PAYLOAD=$(cat <<EOF
{
  "session_id": "${WORKER_SESSION_ID}",
  "machine_id": "${MACHINE_ID}",
  "jobs_processed": ${JOBS_PROCESSED},
  "total_generation_time_sec": ${TOTAL_GEN_TIME}
}
EOF
)

curl -s -X POST "${API_BASE_URL}/v1/worker/off" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${OFF_PAYLOAD}" || true

# ==============================================================================
# 6. Provider Auto-Termination / Hibernation (COMMENTED OUT FOR DEBUGGING)
# ==============================================================================
# if [ "$RUNNER_PLATFORM" = "lium" ] && [ -n "$LIUM_POD_ID" ]; then
#     echo "[Teardown] Terminating Lium Pod: ${LIUM_POD_ID}"
#     curl -s -X DELETE "${LIUM_BASE_URL:-https://lium.io/api}/pods/${LIUM_POD_ID}" \
#         -H "X-API-Key: ${LIUM_API_KEY}" \
#         -H "Accept: application/json" || true
#
# elif [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
#     echo "[Teardown] Hibernating Hyperstack VM..."
#     HYPERSTACK_API_URL="${HYPERSTACK_API_URL:-https://infrahub-api.nexgencloud.com/v1}"
#     VM_ID=$(curl -s -H "api_key: ${HYPERSTACK_API_KEY}" -H "accept: application/json" \
#         "${HYPERSTACK_API_URL}/core/virtual-machines" | \
#         node -e "
#             const fs = require('fs');
#             try {
#                 const data = JSON.parse(fs.readFileSync(0, 'utf-8'));
#                 const match = (data.instances || []).find(v => v.name && v.name.toLowerCase() === '${HYPERSTACK_VM_NAME}'.toLowerCase());
#                 if (match) process.stdout.write(String(match.id));
#             } catch (_) {}
#         ")
#     [ -n "$VM_ID" ] && curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
#         "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true
#
# elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
#     VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"
#     if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
#         curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
#             -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
#             -H "Content-Type: application/json" \
#             -d '{"state": "stopped"}' || true
#     fi
# fi

echo "[Debug] Auto-termination is commented out. Container staying active indefinitely."
sleep infinity

exit $WORKER_EXIT_CODE