# DGX Spark Multi-Node vLLM Ray Deployment

Updated dual-DGX Spark vLLM deployment workflow using NVIDIA vLLM 26.04, Ray, persistent Docker containers, and the 200GbE QSFP/CX7 interconnect.

This repository is intended to help users run newer Hugging Face models, such as `Qwen/Qwen3.6-35B-A3B`, across two NVIDIA DGX Spark nodes using vLLM and Ray.

Repository:

```text
https://github.com/makiisthenes/dgx-spark-multinode-vllm-ray/
```

This workflow builds on NVIDIA’s official DGX Spark vLLM playbook:

```text
https://build.nvidia.com/spark/vllm/stacked-sparks
```

The NVIDIA playbook is a useful starting point, but at the time of writing it uses:

```text
nvcr.io/nvidia/vllm:25.11-py3
```

This workflow uses:

```text
nvcr.io/nvidia/vllm:26.04-py3
```

to get newer vLLM and model support. The newer NVIDIA vLLM container no longer exposes the `ray` command by default, so this repository adds Ray back explicitly through a small Dockerfile and provides persistent cluster scripts.

## What this repository does

This repository provides a repeatable workflow for:

* turning two DGX Spark systems into a small two-node local AI cluster
* using the QSFP/CX7 high-speed link for inter-node traffic
* running a Ray head and Ray worker across both Sparks
* using NVIDIA’s newer vLLM container image
* adding Ray explicitly for Ray-backed distributed inference
* serving a newer model such as `Qwen/Qwen3.6-35B-A3B`
* exposing the model through a local OpenAI-compatible API
* connecting the endpoint to tools such as Open WebUI or Continue

## What this repository does not do

This repository does not provide a prebuilt public Docker image.

The base image is NVIDIA’s NGC vLLM container, which is subject to NVIDIA’s licence terms. Users should build the derived image locally after confirming they have access to and permission to use NVIDIA’s NGC container.

This repository also does not replace NVIDIA’s official DGX Spark networking setup. You should complete and validate the Spark-to-Spark network, SSH, and NCCL steps first.

## High-level architecture

```text
Client / Web UI / Coding Agent
        |
        v
OpenAI-compatible API
        |
        v
vLLM server on Ray head node
        |
        v
Ray distributed runtime
        |
        +-----------------------------+
        |                             |
        v                             v
DGX Spark Head Node             DGX Spark Worker Node
GPU 0                           GPU 0
QSFP/CX7 link-local IP          QSFP/CX7 link-local IP
```

In this setup, the model is not running in one magical pooled memory space. Each DGX Spark still has its own GPU memory. vLLM, Ray, and NCCL coordinate model execution across both GPUs.

## Template variables used in this guide

This README intentionally avoids hard-coded hostnames and private IP addresses. Replace the following template variables with values from your own DGX Spark systems.

| Variable            | Meaning                                                                | Example value                                     |
| ------------------- | ---------------------------------------------------------------------- | ------------------------------------------------- |
| `<HEAD_HOSTNAME>`   | Hostname of the DGX Spark used as the Ray head                         | `dgx-spark-head`                                  |
| `<WORKER_HOSTNAME>` | Hostname of the DGX Spark used as the Ray worker                       | `dgx-spark-worker`                                |
| `<HEAD_QSFP_IP>`    | Link-local or routed IP of the head node on the QSFP/CX7 interface     | `169.254.x.x`                                     |
| `<WORKER_QSFP_IP>`  | Link-local or routed IP of the worker node on the QSFP/CX7 interface   | `169.254.x.x`                                     |
| `<HEAD_LAN_IP>`     | LAN IP of the head node used by browsers, Open WebUI, or coding agents | `192.168.x.x`                                     |
| `<MN_IF_NAME>`      | Active high-speed network interface name                               | `enp1s0f1np1`                                     |
| `<LINUX_USER>`      | Linux user used on both nodes                                          | `nvidia`                                          |
| `<REPO_DIR>`        | Repository path on each node                                           | `/home/<LINUX_USER>/dgx-spark-multinode-vllm-ray` |
| `<VLLM_IMAGE>`      | Locally built Ray-enabled vLLM image                                   | `local/vllm-ray:26.04-py3`                        |
| `<MODEL_ID>`        | Hugging Face model ID to serve                                         | `Qwen/Qwen3.6-35B-A3B`                            |

Recommended default values used by the examples below:

```bash
export LINUX_USER=nvidia
export REPO_DIR="/home/${LINUX_USER}/dgx-spark-multinode-vllm-ray"
export VLLM_IMAGE=local/vllm-ray:26.04-py3
export MODEL_ID=Qwen/Qwen3.6-35B-A3B
```

## How to find your template variables

Run these commands locally on your own systems and substitute the resulting values throughout the guide.

### Find the hostname on each node

Run on each DGX Spark:

```bash
hostname
```

Use the output from the head node as:

```text
<HEAD_HOSTNAME>
```

Use the output from the worker node as:

```text
<WORKER_HOSTNAME>
```

### Find the active QSFP/CX7 interface

Run on each node:

```bash
ibdev2netdev
```

Look for the interface marked `Up`, for example:

```text
rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)
```

Set:

```bash
export MN_IF_NAME=<MN_IF_NAME>
```

Example:

```bash
export MN_IF_NAME=enp1s0f1np1
```

### Find the QSFP/CX7 IP on each node

Run on each node after setting `MN_IF_NAME`:

```bash
ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
```

Use the result from the head node as:

```text
<HEAD_QSFP_IP>
```

Use the result from the worker node as:

```text
<WORKER_QSFP_IP>
```

You can also set it automatically on each node:

```bash
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "$VLLM_HOST_IP"
```

On the head node, `VLLM_HOST_IP` should resolve to `<HEAD_QSFP_IP>`.

On the worker node, `VLLM_HOST_IP` should resolve to `<WORKER_QSFP_IP>`.

### Find the head node LAN IP

The LAN IP is the address you use from your browser or client machine to reach the Ray dashboard, vLLM API, or Open WebUI.

Run on the head node:

```bash
hostname -I
```

Pick the IP address that is reachable from your laptop or workstation. Use it as:

```text
<HEAD_LAN_IP>
```

If you are unsure which IP is reachable, test from your client machine:

```bash
ping <HEAD_LAN_IP>
```

### Confirm the route uses the QSFP/CX7 interface

From the head node:

```bash
ip route get <WORKER_QSFP_IP>
```

Expected style of output:

```text
<WORKER_QSFP_IP> dev <MN_IF_NAME> src <HEAD_QSFP_IP>
```

From the worker node:

```bash
ip route get <HEAD_QSFP_IP>
```

Expected style of output:

```text
<HEAD_QSFP_IP> dev <MN_IF_NAME> src <WORKER_QSFP_IP>
```

This confirms traffic to the other Spark is using the QSFP/CX7 interface.

## Prerequisites

Before starting this vLLM/Ray setup, you should already have completed the two-node DGX Spark networking and NCCL validation steps.

NVIDIA’s vLLM playbook expects the two-Spark setup to include the physical QSFP cable connection, network interface configuration, passwordless SSH, and network connectivity verification. The playbook also starts by downloading `run_cluster.sh`, pulling the NVIDIA vLLM image, starting a Ray head, starting a Ray worker, and checking `ray status`.

You should already have:

* two DGX Spark systems
* QSFP/CX7 cable connected between them
* link-local or routed IPs on the high-speed interface
* SSH working between the nodes
* Docker working for `<LINUX_USER>`
* NVIDIA Container Toolkit working
* NCCL tests passing between the nodes
* a Hugging Face account/token if using gated models

## Step 1: Confirm the high-speed interface

Run this on both nodes:

```bash
ibdev2netdev
```

You should see one interface marked as `Up`, for example:

```text
rocep1s0f1 port 1 ==> <MN_IF_NAME> (Up)
```

Set the interface name:

```bash
export MN_IF_NAME=<MN_IF_NAME>
```

Confirm the IP address on each node:

```bash
ip -4 addr show "$MN_IF_NAME"
```

On the head node, the address should correspond to:

```text
<HEAD_QSFP_IP>
```

On the worker node, the address should correspond to:

```text
<WORKER_QSFP_IP>
```

Confirm routing between nodes.

From the head node:

```bash
ip route get <WORKER_QSFP_IP>
```

Expected style of output:

```text
<WORKER_QSFP_IP> dev <MN_IF_NAME> src <HEAD_QSFP_IP>
```

From the worker node:

```bash
ip route get <HEAD_QSFP_IP>
```

Expected style of output:

```text
<HEAD_QSFP_IP> dev <MN_IF_NAME> src <WORKER_QSFP_IP>
```

This confirms traffic to the other Spark is using the QSFP/CX7 interface.

## Step 2: Confirm link speed

Run this on each node against the active interface:

```bash
sudo ethtool <MN_IF_NAME>
```

Look for:

```text
Speed: 200000Mb/s
Link detected: yes
```

This confirms the physical link is negotiated at 200Gb/s.

## Step 3: Confirm SSH between nodes

From the head node:

```bash
ssh <WORKER_QSFP_IP> hostname
```

Expected:

```text
<WORKER_HOSTNAME>
```

From the worker node:

```bash
ssh <HEAD_QSFP_IP> hostname
```

Expected:

```text
<HEAD_HOSTNAME>
```

For this workflow, use the same Linux user on both nodes, ideally:

```text
<LINUX_USER>
```

This avoids confusion with SSH keys, Docker permissions, and home-directory paths.

## Step 4: Confirm Docker works as the selected Linux user

Run this on both nodes:

```bash
whoami
groups
docker ps
```

If `docker ps` fails with a permission error, add your Linux user to the Docker group from a sudo-capable account:

```bash
sudo usermod -aG docker <LINUX_USER>
```

Then log out and back in as `<LINUX_USER>`, or run:

```bash
newgrp docker
```

Test again:

```bash
docker ps
```

## Step 5: Clone this repository on both nodes

Run this on both nodes from the selected user’s home directory:

```bash
cd /home/<LINUX_USER>
git clone https://github.com/makiisthenes/dgx-spark-multinode-vllm-ray.git
cd dgx-spark-multinode-vllm-ray
```

If you are manually copying files instead of cloning the repo, make sure both nodes have the same files in the same directory.

Set the repository directory:

```bash
export REPO_DIR=/home/<LINUX_USER>/dgx-spark-multinode-vllm-ray
```

## Step 6: Why this repo uses NVIDIA vLLM 26.04

NVIDIA’s current DGX Spark vLLM playbook pulls:

```bash
nvcr.io/nvidia/vllm:25.11-py3
```

That older image works with the tutorial’s Ray-based flow, but it may not support newer model architectures such as Qwen3.6. In testing, `Qwen/Qwen3.6-35B-A3B` required newer model support than the older container stack provided.

The newer NVIDIA image:

```bash
nvcr.io/nvidia/vllm:26.04-py3
```

includes a newer vLLM stack, but Ray is not included by default. vLLM now treats Ray as an optional dependency. The vLLM documentation describes both Ray-based and multiprocessing-based multi-node deployment paths, and explicitly shows Ray as an optional install for Ray-based execution.

This repo keeps the Ray-based workflow because:

* it is close to NVIDIA’s original DGX Spark playbook
* it gives useful cluster visibility through the Ray dashboard
* it makes the head/worker model easier to reason about
* it works well with the existing `run_cluster.sh` style workflow

## Step 7: Build the Ray-enabled vLLM image

Create or confirm this `Dockerfile` exists in the repository:

```dockerfile
FROM nvcr.io/nvidia/vllm:26.04-py3

# Ray is optional in newer vLLM releases, but required for this Ray-backed
# multi-node vLLM workflow. ray[default] includes dashboard dependencies.
RUN pip install --no-cache-dir "ray[default]"

# Build-time sanity check that does not require GPU access.
RUN python3 -c "import ray; print('Ray version:', ray.__version__)"
```

Important: do not run `vllm --version` as a Docker build-time check. During `docker build`, GPU access is not available, and vLLM may fail while trying to infer the CUDA device.

Build the image on both nodes:

```bash
cd "$REPO_DIR"
docker build -t <VLLM_IMAGE> .
```

Example:

```bash
cd "$REPO_DIR"
docker build -t local/vllm-ray:26.04-py3 .
```

Test the image at runtime:

```bash
docker run --rm --gpus all <VLLM_IMAGE> /bin/bash -lc 'ray --version && vllm --version'
```

Expected style of output:

```text
ray, version 2.x.x
0.19.0+...nv26.04...
```

If this works on both nodes, continue.

## Step 8: Understand the persistent cluster script

NVIDIA’s original `run_cluster.sh` starts a Ray node inside Docker and keeps the terminal open. Closing the terminal stops the associated Ray node.

This repository uses a persistent version of that script.

The persistent script changes the behaviour in several ways:

* uses fixed container names
* runs Docker detached in the background
* adds Docker restart policy
* binds the Ray dashboard to `0.0.0.0`
* avoids random `node-<number>` container names
* makes the cluster easier to inspect and stop
* adds shared-memory and ulimit options useful for newer vLLM containers

The fixed container names are:

```text
vllm-ray-head
vllm-ray-worker
```

Typical operations become:

```bash
docker ps
docker logs -f vllm-ray-head
docker logs -f vllm-ray-worker
docker exec vllm-ray-head ray status
docker stop vllm-ray-worker
docker stop vllm-ray-head
```

## Step 9: Make scripts executable

On both nodes:

```bash
cd "$REPO_DIR"
chmod +x run_cluster_persistent.sh
```

If using the multiprocessing helper script as well:

```bash
chmod +x run_vllm_mp_persistent.sh
```

## Step 10: Start the Ray head node

Run this on the head node.

Set environment variables:

```bash
export VLLM_IMAGE=<VLLM_IMAGE>
export MN_IF_NAME=<MN_IF_NAME>
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo "Using interface $MN_IF_NAME with IP $VLLM_HOST_IP"
```

Expected:

```text
Using interface <MN_IF_NAME> with IP <HEAD_QSFP_IP>
```

Start the head container:

```bash
cd "$REPO_DIR"

bash run_cluster_persistent.sh "$VLLM_IMAGE" "$VLLM_HOST_IP" --head ~/.cache/huggingface \
  -e VLLM_HOST_IP="$VLLM_HOST_IP" \
  -e UCX_NET_DEVICES="$MN_IF_NAME" \
  -e NCCL_SOCKET_IFNAME="$MN_IF_NAME" \
  -e OMPI_MCA_btl_tcp_if_include="$MN_IF_NAME" \
  -e GLOO_SOCKET_IFNAME="$MN_IF_NAME" \
  -e TP_SOCKET_IFNAME="$MN_IF_NAME" \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR="$VLLM_HOST_IP"
```

Check that the container is running:

```bash
docker ps
```

Expected:

```text
vllm-ray-head
```

Check the logs:

```bash
docker logs --tail 100 vllm-ray-head
```

You should see Ray start successfully.

## Step 11: Start the Ray worker node

Run this on the worker node.

Set environment variables:

```bash
export VLLM_IMAGE=<VLLM_IMAGE>
export MN_IF_NAME=<MN_IF_NAME>
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export HEAD_NODE_IP=<HEAD_QSFP_IP>

echo "Worker IP: $VLLM_HOST_IP, connecting to head node at: $HEAD_NODE_IP"
```

Expected:

```text
Worker IP: <WORKER_QSFP_IP>, connecting to head node at: <HEAD_QSFP_IP>
```

Start the worker container:

```bash
cd "$REPO_DIR"

bash run_cluster_persistent.sh "$VLLM_IMAGE" "$HEAD_NODE_IP" --worker ~/.cache/huggingface \
  -e VLLM_HOST_IP="$VLLM_HOST_IP" \
  -e UCX_NET_DEVICES="$MN_IF_NAME" \
  -e NCCL_SOCKET_IFNAME="$MN_IF_NAME" \
  -e OMPI_MCA_btl_tcp_if_include="$MN_IF_NAME" \
  -e GLOO_SOCKET_IFNAME="$MN_IF_NAME" \
  -e TP_SOCKET_IFNAME="$MN_IF_NAME" \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR="$HEAD_NODE_IP"
```

Check that the container is running:

```bash
docker ps
```

Expected:

```text
vllm-ray-worker
```

Check the logs:

```bash
docker logs --tail 100 vllm-ray-worker
```

Expected style of output:

```text
Ray runtime started.
This command will now block forever until terminated by a signal.
```

That is normal. The worker container is waiting for work from the Ray head.

## Step 12: Verify the Ray cluster

Run this on the head node:

```bash
docker exec vllm-ray-head ray status
```

Expected:

```text
2 active nodes
2.0 GPU total
no pending nodes
no recent failures
```

You can also run:

```bash
docker exec vllm-ray-head ray list nodes
```

This should show both node IPs.

If you see only one node, the worker has not joined. Check the worker logs:

```bash
docker logs --tail 100 vllm-ray-worker
```

Also check that the worker can reach the head:

```bash
ssh <HEAD_QSFP_IP> hostname
```

## Step 13: Open the Ray dashboard

The persistent script starts the Ray head with:

```text
--dashboard-host=0.0.0.0
--dashboard-port=8265
```

From a browser on the LAN, open:

```text
http://<HEAD_LAN_IP>:8265
```

If the dashboard is not accessible, test from the head node:

```bash
curl -I http://127.0.0.1:8265
```

If local access works but LAN access does not, use an SSH tunnel from your client machine:

```bash
ssh -L 8265:127.0.0.1:8265 <LINUX_USER>@<HEAD_LAN_IP>
```

Then open:

```text
http://127.0.0.1:8265
```

## Step 14: Authenticate with Hugging Face

Enter the head container:

```bash
docker exec -it vllm-ray-head /bin/bash
```

Log in:

```bash
hf auth login
```

Do not commit your Hugging Face token to this repository.

If prompted:

```text
Add token as git credential?
```

You can answer `n` unless you specifically plan to use Git/Git LFS to clone Hugging Face repositories.

## Step 15: Download the model

Inside the head container:

```bash
hf download <MODEL_ID>
```

Example:

```bash
hf download Qwen/Qwen3.6-35B-A3B
```

For best reliability, download the model on both nodes so the files are available in each node’s mounted Hugging Face cache.

On the worker node:

```bash
docker exec -it vllm-ray-worker /bin/bash
hf auth login
hf download <MODEL_ID>
```

Exit the containers when finished:

```bash
exit
```

## Step 16: Serve the model across both nodes

Run this on the head node:

```bash
docker exec -it vllm-ray-head /bin/bash -c '
vllm serve <MODEL_ID> \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --distributed-executor-backend ray \
  --max-model-len 8192 \
  --reasoning-parser qwen3 \
  --gpu-memory-utilization 0.7
'
```

Example:

```bash
docker exec -it vllm-ray-head /bin/bash -c '
vllm serve Qwen/Qwen3.6-35B-A3B \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --distributed-executor-backend ray \
  --max-model-len 8192 \
  --reasoning-parser qwen3 \
  --gpu-memory-utilization 0.7
'
```

This starts the vLLM API server on the head node.

Important flags:

```text
--host 0.0.0.0
```

Allows the API to listen beyond localhost.

```text
--port 8000
```

Serves the OpenAI-compatible API on port 8000.

```text
--tensor-parallel-size 2
```

Uses two GPUs total.

```text
--distributed-executor-backend ray
```

Tells vLLM to use the Ray cluster.

```text
--max-model-len 8192
```

Limits context length for the first working run.

```text
--reasoning-parser qwen3
```

Uses the Qwen3 reasoning parser.

```text
--gpu-memory-utilization 0.7
```

Keeps memory use more conservative, which is useful on DGX Spark.

## Step 17: Know when the model is serving

In the vLLM logs, you should see the model load successfully:

```text
Resolved architecture: Qwen3_5MoeForConditionalGeneration
Loading safetensors checkpoint shards: 100%
Model loading took ...
Application startup complete.
```

Once it is ready, test from the head node:

```bash
curl http://localhost:8000/v1/models
```

Expected: JSON response listing the model.

Then test chat completions:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<MODEL_ID>",
    "messages": [
      {
        "role": "user",
        "content": "Explain tensor parallelism in one sentence."
      }
    ],
    "max_tokens": 64,
    "temperature": 0.7
  }'
```

If this returns a model response, vLLM is serving correctly.

For the example model, use:

```json
"model": "Qwen/Qwen3.6-35B-A3B"
```

## Step 18: Understand head versus worker logs

The head node runs the API server. You will see request logs there:

```text
GET /v1/models 200 OK
POST /v1/chat/completions 200 OK
Avg generation throughput ...
```

The worker node logs may look quiet:

```text
Ray runtime started.
This command will now block forever until terminated by a signal.
```

That is normal. The worker is not an HTTP API server. It participates through Ray as a distributed worker.

The head logs may include entries like:

```text
RayWorkerWrapper ... ip=<WORKER_QSFP_IP>
```

That confirms the worker node is participating.

## Step 19: Watch GPU usage

On both nodes:

```bash
watch -n 1 nvidia-smi
```

During a generation request, both GPUs should show memory/process usage.

Ray dashboard should also show:

```text
2.0/2.0 GPU used or reserved
```

## Step 20: Connect Open WebUI

Once vLLM is serving on the head node, the API endpoint is:

```text
http://<HEAD_LAN_IP>:8000/v1
```

Start Open WebUI:

```bash
docker run -d \
  --name open-webui-vllm \
  --restart always \
  -p 3000:8080 \
  -v open-webui-vllm:/app/backend/data \
  -e OPENAI_API_BASE_URL=http://<HEAD_LAN_IP>:8000/v1 \
  -e OPENAI_API_KEY=dummy \
  ghcr.io/open-webui/open-webui:main
```

Then open:

```text
http://<HEAD_LAN_IP>:3000
```

Use:

```text
API Base URL: http://<HEAD_LAN_IP>:8000/v1
API Key: dummy
```

## Step 21: Connect Continue or another coding agent

Example Continue-style config:

```yaml
name: DGX Spark Local vLLM
version: 1.0.0
schema: v1

models:
  - name: DGX Spark Qwen3.6 35B
    provider: openai
    model: Qwen/Qwen3.6-35B-A3B
    apiBase: http://<HEAD_LAN_IP>:8000/v1
    apiKey: dummy
    roles:
      - chat
      - edit
      - apply

context:
  - provider: code
  - provider: docs
  - provider: diff
  - provider: terminal
  - provider: problems

rules:
  - name: Careful local coding
    rule: |
      You are connected to a locally hosted vLLM model running on dual DGX Spark nodes.
      Prefer small, safe, reviewable code changes.
      Explain assumptions before making broad architectural changes.
      Do not invent files or APIs that are not present in the repository.
```

## Step 22: Stop the model server

If you started `vllm serve` interactively, stop it with:

```text
Ctrl+C
```

This stops the model API and should release GPU memory.

Ray remains running.

## Step 23: Stop the Ray cluster

Stop the worker first:

```bash
docker stop vllm-ray-worker
```

Then stop the head:

```bash
docker stop vllm-ray-head
```

Because the containers use:

```text
--restart unless-stopped
```

Docker should not restart them after a manual `docker stop`.

Remove them if needed:

```bash
docker rm vllm-ray-worker
docker rm vllm-ray-head
```

## Step 24: Restart the cluster later

On the head node:

```bash
cd "$REPO_DIR"

export VLLM_IMAGE=<VLLM_IMAGE>
export MN_IF_NAME=<MN_IF_NAME>
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

bash run_cluster_persistent.sh "$VLLM_IMAGE" "$VLLM_HOST_IP" --head ~/.cache/huggingface \
  -e VLLM_HOST_IP="$VLLM_HOST_IP" \
  -e UCX_NET_DEVICES="$MN_IF_NAME" \
  -e NCCL_SOCKET_IFNAME="$MN_IF_NAME" \
  -e OMPI_MCA_btl_tcp_if_include="$MN_IF_NAME" \
  -e GLOO_SOCKET_IFNAME="$MN_IF_NAME" \
  -e TP_SOCKET_IFNAME="$MN_IF_NAME" \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR="$VLLM_HOST_IP"
```

On the worker node:

```bash
cd "$REPO_DIR"

export VLLM_IMAGE=<VLLM_IMAGE>
export MN_IF_NAME=<MN_IF_NAME>
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export HEAD_NODE_IP=<HEAD_QSFP_IP>

bash run_cluster_persistent.sh "$VLLM_IMAGE" "$HEAD_NODE_IP" --worker ~/.cache/huggingface \
  -e VLLM_HOST_IP="$VLLM_HOST_IP" \
  -e UCX_NET_DEVICES="$MN_IF_NAME" \
  -e NCCL_SOCKET_IFNAME="$MN_IF_NAME" \
  -e OMPI_MCA_btl_tcp_if_include="$MN_IF_NAME" \
  -e GLOO_SOCKET_IFNAME="$MN_IF_NAME" \
  -e TP_SOCKET_IFNAME="$MN_IF_NAME" \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR="$HEAD_NODE_IP"
```

Then start the model again from the head node.

## Troubleshooting

### `ray: command not found`

You are probably using `nvcr.io/nvidia/vllm:26.04-py3` directly.

That image contains newer vLLM, but Ray is not exposed by default.

Use the custom image:

```bash
<VLLM_IMAGE>
```

Example:

```bash
local/vllm-ray:26.04-py3
```

Build it:

```bash
docker build -t <VLLM_IMAGE> .
```

### Docker container keeps restarting with exit code 127

Exit code 127 often means a command was not found.

Check logs:

```bash
docker logs vllm-ray-head
```

If the missing command is `ray`, rebuild the custom image with Ray installed.

### Dashboard does not open

Check the head logs:

```bash
docker logs --tail 100 vllm-ray-head
```

Check if port 8265 is listening:

```bash
ss -ltnp | grep 8265
```

Test locally:

```bash
curl -I http://127.0.0.1:8265
```

If local works but LAN does not, use SSH port forwarding:

```bash
ssh -L 8265:127.0.0.1:8265 <LINUX_USER>@<HEAD_LAN_IP>
```

Then open:

```text
http://127.0.0.1:8265
```

### `Node type must be --head or --worker`

One of your variables is probably empty, usually `VLLM_IMAGE`.

Check:

```bash
echo "$VLLM_IMAGE"
echo "$VLLM_HOST_IP"
echo "$MN_IF_NAME"
```

Set them again:

```bash
export VLLM_IMAGE=<VLLM_IMAGE>
export MN_IF_NAME=<MN_IF_NAME>
export VLLM_HOST_IP=$(ip -4 addr show "$MN_IF_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
```

Use quotes around variables in script commands:

```bash
bash run_cluster_persistent.sh "$VLLM_IMAGE" "$VLLM_HOST_IP" --head ~/.cache/huggingface ...
```

### Model architecture not recognised

This usually means the vLLM/Transformers stack is too old.

An older NVIDIA image may fail with an error similar to:

```text
model type qwen3_5_moe but Transformers does not recognise this architecture
```

Do not fix this by blindly upgrading Transformers inside the old container. That can break the pinned NVIDIA vLLM stack.

Use the newer NVIDIA vLLM image plus the custom Ray-enabled Dockerfile.

### Worker logs are quiet

This is normal.

The worker does not run the HTTP server. It waits for Ray tasks from the head.

Look for worker participation in the head logs, for example:

```text
RayWorkerWrapper ... ip=<WORKER_QSFP_IP>
```

### Only one API endpoint exists

This is expected.

The API server runs on the head node only:

```text
http://<HEAD_LAN_IP>:8000/v1
```

The worker node does not expose a separate API.

### `max-model-len` is too high

Start small.

Suggested progression:

```text
2048    first smoke test
8192    normal test
32768   larger context test
65536   serious long-context test
131072  half of a 262k context model
262144  full advertised context, if memory allows
```

Larger context lengths require more KV-cache memory.

### Port 8000 does not respond

Check whether vLLM is still loading.

Look for:

```text
Application startup complete
```

Test:

```bash
curl http://localhost:8000/v1/models
```

Check the process:

```bash
docker exec vllm-ray-head pgrep -af "vllm serve"
```

### Docker permissions denied

Add the user to the Docker group:

```bash
sudo usermod -aG docker <LINUX_USER>
```

Log out and back in, then test:

```bash
docker ps
```

## Ray versus multiprocessing

Newer vLLM supports multi-node deployment through both Ray and multiprocessing.

This repository keeps a Ray-based path because it is close to NVIDIA’s original DGX Spark playbook and gives a useful dashboard and cluster observability.

A multiprocessing helper script can also be used for a no-Ray approach. In that mode, you run `vllm serve` on both nodes with flags such as:

```text
--nnodes
--node-rank
--master-addr
--headless
```

This can be simpler in future vLLM releases, but the Ray path remains useful for people following the original DGX Spark tutorial.

## Notes on model formats and runtimes

For this two-node vLLM workflow, start with Hugging Face / safetensors models that are supported by vLLM.

General mental model:

```text
Safetensors / Hugging Face:
  vLLM, Transformers, TensorRT-LLM, SGLang

GGUF:
  llama.cpp, LM Studio, koboldcpp, Ollama-style stacks

FP8 / NVFP4 Hugging Face repos:
  vLLM or TensorRT-LLM if supported
```

For this repository:

```text
Use vLLM for distributed two-Spark serving.
Use Hugging Face / safetensors / NVIDIA-supported models first.
Avoid GGUF for this Ray/vLLM multi-node path.
```

## References

NVIDIA DGX Spark vLLM playbook:

```text
https://build.nvidia.com/spark/vllm/stacked-sparks
```

Repository:

```text
https://github.com/makiisthenes/dgx-spark-multinode-vllm-ray/
```

NVIDIA NGC vLLM container:

```text
https://catalog.ngc.nvidia.com/orgs/nvidia/containers/vllm
```

vLLM multi-node deployment documentation:

```text
https://docs.vllm.ai/en/latest/serving/parallelism_scaling/
```

Qwen3.6 model:

```text
https://huggingface.co/Qwen/Qwen3.6-35B-A3B
```
