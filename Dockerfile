FROM nvcr.io/nvidia/vllm:26.04-py3

# Ray is optional in newer vLLM releases, but required for Ray-backed
# multi-node vLLM deployments using run_cluster.sh-style workflows.
RUN pip install --no-cache-dir "ray[cgraph]"

# Build-time sanity check.
RUN vllm --version && python3 -c "import ray; print('Ray version:', ray.__version__)"
