FROM vllm/vllm-openai:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
      wireguard-tools iproute2 iptables ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8000 51820/udp
ENTRYPOINT ["/start.sh"]
