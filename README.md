# DGX Spark vLLM Ray Container
Updated dual-DGX Spark vLLM deployment workflow using NVIDIA vLLM 26.04, Ray, persistent Docker containers, and 200GbE QSFP interconnect.


This repository provides a small Dockerfile and helper script for running a Ray-backed vLLM cluster across two NVIDIA DGX Spark nodes.
The documentation @ https://build.nvidia.com/spark/vllm wasn't really helpful when I wanted to use newer models like Qwen3.6, the docs relies on packages which are 4 months old.

Latest: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/vllm?version=26.04-py3

Current nvidia vllm module no longer includes Ray (now multiprocessing) but for the sack of compatability I kept Ray.



Disclaimer

I cannot publish a prebuilt image because the base image is NVIDIA's NGC vLLM container, which is subject to NVIDIA's licence terms. Users should build the image locally after ensuring they have access to and permission to use the NVIDIA NGC container.

