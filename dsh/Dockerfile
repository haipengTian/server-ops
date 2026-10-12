# DeepSeek Harness 运行镜像（官方没有提供 Docker 镜像，这里基于 npm 包自建）
# Node 版本要求：^22.19 或 >=24；用 Debian 而不是 Alpine，避免依赖里的原生模块缺 glibc
FROM node:24-bookworm-slim

ARG DSH_VERSION

# 智能体干活常用的命令行工具；bubblewrap 是 dsh 在 Linux 上首选的命令沙箱
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates git curl bash python3 ripgrep procps less bubblewrap \
    && rm -rf /var/lib/apt/lists/*

RUN test -n "$DSH_VERSION" \
    && npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
    && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod 755 /usr/local/bin/dsh-entrypoint

# 以镜像自带的 node 用户（uid 1000）运行，不用 root
ENV DSH_HOME=/data/home
USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
