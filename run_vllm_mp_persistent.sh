#!/bin/bash
#
# Persistent multi-node vLLM launcher using the multiprocessing backend.
#
# This script starts vLLM inside Docker across multiple nodes without Ray.
#
# Usage on head node:
#   ./run_vllm_mp_persistent.sh \
#     --image nvcr.io/nvidia/vllm:26.04-py3 \
#     --model Qwen/Qwen3.6-35B-A3B \
#     --head-ip <HEAD_NODE_IP> \
#     --node-rank 0 \
#     --nnodes 2 \
#     --hf-cache ~/.cache/huggingface \
#     -- \
#     --tensor-parallel-size 1 \
#     --pipeline-parallel-size 2 \
#     --max-model-len 8192 \
#     --reasoning-parser qwen3 \
#     --gpu-memory-utilization 0.7
#
# Usage on worker node:
#   ./run_vllm_mp_persistent.sh \
#     --image nvcr.io/nvidia/vllm:26.04-py3 \
#     --model Qwen/Qwen3.6-35B-A3B \
#     --head-ip <HEAD_NODE_IP> \
#     --node-rank 1 \
#     --nnodes 2 \
#     --hf-cache ~/.cache/huggingface \
#     -- \
#     --tensor-parallel-size 1 \
#     --pipeline-parallel-size 2 \
#     --max-model-len 8192 \
#     --reasoning-parser qwen3 \
#     --gpu-memory-utilization 0.7
#
# Notes:
#   - node-rank 0 is the head/API node.
#   - node-rank 1, 2, ... are workers.
#   - Workers run with --headless automatically.
#   - Use private high-speed interface IPs for --head-ip.
#   - Do not commit Hugging Face tokens into this file or a public repo.

set -euo pipefail

IMAGE=""
MODEL=""
HEAD_IP=""
NODE_RANK=""
NNODES=""
HF_CACHE="$HOME/.cache/huggingface"
CONTAINER_PREFIX="vllm-mp"
HOST="0.0.0.0"
PORT="8000"

VLLM_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --head-ip)
            HEAD_IP="$2"
            shift 2
            ;;
        --node-rank)
            NODE_RANK="$2"
            shift 2
            ;;
        --nnodes)
            NNODES="$2"
            shift 2
            ;;
        --hf-cache)
            HF_CACHE="$2"
            shift 2
            ;;
        --container-prefix)
            CONTAINER_PREFIX="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --)
            shift
            VLLM_ARGS=("$@")
            break
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$IMAGE" || -z "$MODEL" || -z "$HEAD_IP" || -z "$NODE_RANK" || -z "$NNODES" ]]; then
    echo "Missing required arguments."
    echo
    echo "Required:"
    echo "  --image <docker_image>"
    echo "  --model <model_or_path>"
    echo "  --head-ip <head_node_ip>"
    echo "  --node-rank <0_for_head_1_plus_for_workers>"
    echo "  --nnodes <number_of_nodes>"
    echo
    exit 1
fi

mkdir -p "$HF_CACHE"

if [[ "$NODE_RANK" == "0" ]]; then
    CONTAINER_NAME="${CONTAINER_PREFIX}-head"
    HEADLESS_ARG=""
else
    CONTAINER_NAME="${CONTAINER_PREFIX}-worker-${NODE_RANK}"
    HEADLESS_ARG="--headless"
fi

echo "Docker image:     $IMAGE"
echo "Model:            $MODEL"
echo "Container:        $CONTAINER_NAME"
echo "Head IP:          $HEAD_IP"
echo "Node rank:        $NODE_RANK"
echo "Total nodes:      $NNODES"
echo "HF cache:         $HF_CACHE"
echo "Host/port:        $HOST:$PORT"
echo "Extra vLLM args:  ${VLLM_ARGS[*]:-none}"
echo

VLLM_CMD="vllm serve \"$MODEL\" \
  --host \"$HOST\" \
  --port \"$PORT\" \
  --distributed-executor-backend mp \
  --nnodes \"$NNODES\" \
  --node-rank \"$NODE_RANK\" \
  --master-addr \"$HEAD_IP\" \
  ${HEADLESS_ARG} \
  ${VLLM_ARGS[*]}"

echo "vLLM command:"
echo "$VLLM_CMD"
echo

echo "Removing existing container named $CONTAINER_NAME if present..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Starting persistent vLLM container..."

DOCKER_ENV_ARGS=()

if [[ -n "${HF_TOKEN:-}" ]]; then
    DOCKER_ENV_ARGS+=("-e" "HF_TOKEN=${HF_TOKEN}")
fi

docker run -d \
    --entrypoint /bin/bash \
    --network host \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --shm-size 16g \
    --gpus all \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    "${DOCKER_ENV_ARGS[@]}" \
    "$IMAGE" \
    -lc "$VLLM_CMD"

echo
echo "Started $CONTAINER_NAME."
echo
echo "Check:"
echo "  docker ps"
echo "  docker logs -f $CONTAINER_NAME"
echo
echo "Stop:"
echo "  docker stop $CONTAINER_NAME"
echo
if [[ "$NODE_RANK" == "0" ]]; then
    echo "API endpoint:"
    echo "  http://<head-node-ip>:${PORT}/v1/models"
    echo
fi
