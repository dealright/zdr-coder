# vLLM + Tailscale image for the rented 8xH100 host.
# Build:  docker build -t YOUR_REGISTRY/kimi-gpu:latest .
# Push:   docker push YOUR_REGISTRY/kimi-gpu:latest
# Run:    deployed on RunPod / Salad / Vast with TS_AUTHKEY, TS_HOSTNAME, HF_TOKEN env vars.

FROM vllm/vllm-openai:latest

# Install Tailscale daemon
RUN apt-get update && apt-get install -y curl iptables ca-certificates \
 && curl -fsSL https://tailscale.com/install.sh | sh \
 && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8000
ENTRYPOINT ["/start.sh"]
