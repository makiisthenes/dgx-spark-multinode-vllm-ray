#!/bin/bash
#
# Persistent Ray cluster launcher for vLLM on DGX Spark.
#
# This is based on vLLM's run_cluster.sh, but changed so that:
#   - Docker runs detached in the background
#   - the container is not removed when the SSH session exits
#   - the container restarts after reboot unless manually stopped
#   - the Ray dashboard on the head node listens on 0.0.0.0:8265
#
# Usage on head node:
#   bash run_cluster_persistent.sh \
#     $VLLM_IMAGE \
#     <head_node_ip> \
#     --head \
#     ~/.cache/huggingface \
#     -e VLLM_HOST_IP=<head_node_ip>
#
# Usage on worker node:
#   bash run_cluster_persistent.sh \
#     $VLLM_IMAGE \
#     <head_node_ip> \
#     --worker \
#     ~/.cache/huggingface \
#     -e VLLM_HOST_IP=<worker_node_ip>
#
# Example for your setup:
#
# Head: spark-b078 / 169.254.11.90
#   bash run_cluster_persistent.sh $VLLM_IMAGE 169.254.11.90 --head ~/.cache/huggingface \
#     -e VLLM_HOST_IP=169.254.11.90
#
# Worker: spark-acfd / 169.254.149.114
#   bash run_cluster_persistent.sh $VLLM_IMAGE 169.254.11.90 --worker ~/.cache/huggingface \
#     -e VLLM_HOST_IP=169.254.149.114
#
# Check:
#   docker ps
#   docker logs -f vllm-ray-head
#   docker logs -f vllm-ray-worker
#
# Stop:
#   docker stop vllm-ray-head
#   docker stop vllm-ray-worker
#
# Disable restart:
#   docker update --restart=no vllm-ray-head
#   docker update --restart=no vllm-ray-worker

set -euo pipefail

if [ $# -lt 4 ]; then
    echo "Usage: $0 docker_image head_node_ip --head|--worker path_to_hf_home [additional_docker_args...]"
    exit 1
fi

DOCKER_IMAGE="$1"
HEAD_NODE_ADDRESS="$2"
NODE_TYPE="$3"
PATH_TO_HF_HOME="$4"
shift 4

ADDITIONAL_ARGS=("$@")

if [ "${NODE_TYPE}" != "--head" ] && [ "${NODE_TYPE}" != "--worker" ]; then
    echo "Error: Node type must be --head or --worker"
    exit 1
fi

if [ ! -d "${PATH_TO_HF_HOME}" ]; then
    echo "Creating Hugging Face cache directory: ${PATH_TO_HF_HOME}"
    mkdir -p "${PATH_TO_HF_HOME}"
fi

VLLM_HOST_IP=""

for ((i = 0; i < ${#ADDITIONAL_ARGS[@]}; i++)); do
    arg="${ADDITIONAL_ARGS[$i]}"

    case "${arg}" in
        -e)
            next="${ADDITIONAL_ARGS[$((i + 1))]:-}"
            if [[ "${next}" == VLLM_HOST_IP=* ]]; then
                VLLM_HOST_IP="${next#VLLM_HOST_IP=}"
                break
            fi
            ;;
        -eVLLM_HOST_IP=*)
            VLLM_HOST_IP="${arg#-eVLLM_HOST_IP=}"
            break
            ;;
        VLLM_HOST_IP=*)
            VLLM_HOST_IP="${arg#VLLM_HOST_IP=}"
            break
            ;;
    esac
done

if [ -z "${VLLM_HOST_IP}" ]; then
    echo "Warning: VLLM_HOST_IP was not provided."
    echo "It is strongly recommended to pass: -e VLLM_HOST_IP=<this_node_cluster_ip>"
fi

if [ "${NODE_TYPE}" == "--head" ]; then
    CONTAINER_NAME="vllm-ray-head"

    if [ -n "${VLLM_HOST_IP}" ] && [ "${VLLM_HOST_IP}" != "${HEAD_NODE_ADDRESS}" ]; then
        echo "Warning: VLLM_HOST_IP (${VLLM_HOST_IP}) differs from head_node_ip (${HEAD_NODE_ADDRESS})."
        echo "Using VLLM_HOST_IP as the Ray head node IP."
        HEAD_NODE_ADDRESS="${VLLM_HOST_IP}"
    fi
else
    CONTAINER_NAME="vllm-ray-worker"
fi

echo "Docker image:       ${DOCKER_IMAGE}"
echo "Container name:     ${CONTAINER_NAME}"
echo "Node type:          ${NODE_TYPE}"
echo "Head node address:  ${HEAD_NODE_ADDRESS}"
echo "This node IP:       ${VLLM_HOST_IP:-not set}"
echo "HF cache path:      ${PATH_TO_HF_HOME}"

RAY_START_CMD="ray start --block"

if [ "${NODE_TYPE}" == "--head" ]; then
    RAY_START_CMD+=" --head"
    RAY_START_CMD+=" --node-ip-address=${HEAD_NODE_ADDRESS}"
    RAY_START_CMD+=" --port=6379"
    RAY_START_CMD+=" --dashboard-host=0.0.0.0"
    RAY_START_CMD+=" --dashboard-port=8265"
else
    RAY_START_CMD+=" --address=${HEAD_NODE_ADDRESS}:6379"

    if [ -n "${VLLM_HOST_IP}" ]; then
        RAY_START_CMD+=" --node-ip-address=${VLLM_HOST_IP}"
    fi
fi

echo "Ray command:"
echo "${RAY_START_CMD}"

echo "Removing any existing container named ${CONTAINER_NAME}..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting persistent Docker container..."

docker run -d \
    --entrypoint /bin/bash \
    --network host \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --shm-size 10.24g \
    --gpus all \
    -v "${PATH_TO_HF_HOME}:/root/.cache/huggingface" \
    "${ADDITIONAL_ARGS[@]}" \
    "${DOCKER_IMAGE}" \
    -c "${RAY_START_CMD}"

echo
echo "Started ${CONTAINER_NAME}."
echo
echo "Check container:"
echo "  docker ps"
echo
echo "View logs:"
echo "  docker logs -f ${CONTAINER_NAME}"
echo
echo "Stop container:"
echo "  docker stop ${CONTAINER_NAME}"
echo
echo "Disable auto-restart:"
echo "  docker update --restart=no ${CONTAINER_NAME}"
echo
if [ "${NODE_TYPE}" == "--head" ]; then
    echo "Ray dashboard should be available at:"
    echo "  http://127.0.0.1:8265"
    echo "  http://<head-node-LAN-IP>:8265"
    echo
fi
