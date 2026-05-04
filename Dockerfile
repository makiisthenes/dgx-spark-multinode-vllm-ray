FROM nvcr.io/nvidia/vllm:26.04-py3

# Ray is optional in newer vLLM releases, but required for this Ray-backed
# multi-node vLLM workflow.
RUN pip install --no-cache-dir "ray[default]"

RUN python3 -c "import ray; print('Ray version:', ray.__version__)"
