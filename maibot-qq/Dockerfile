ARG PYTHON_IMAGE=python:3.13-slim
FROM ${PYTHON_IMAGE} AS system
RUN apt-get update && apt-get install -y --no-install-recommends git ffmpeg \
    && rm -rf /var/lib/apt/lists/*

FROM system AS source
WORKDIR /source
RUN git init && git remote add origin https://github.com/Mai-with-u/MaiBot.git \
    && git fetch --depth 1 origin 2a9af62cec37035d29237acbe2cf3adceb700b27 \
    && git checkout --detach FETCH_HEAD
COPY image/local-fixes.patch /tmp/local-fixes.patch
RUN git apply --check /tmp/local-fixes.patch && git apply /tmp/local-fixes.patch
RUN git clone https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter.git /adapter \
    && git -C /adapter checkout --detach 17ad5384e0d231ec190705c9c2baa234013aaa07 \
    && rm -rf /adapter/.git

FROM ghcr.io/astral-sh/uv:0.13.0 AS uv
FROM system
COPY --from=uv /uv /bin/uv
WORKDIR /opt/maibot
COPY --from=source /source/pyproject.toml ./
COPY image/uv.lock ./uv.lock
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev --no-install-project
RUN --mount=type=cache,target=/root/.cache/uv uv pip install silk-python==0.2.9
RUN .venv/bin/python -m playwright install-deps chromium && rm -rf /var/lib/apt/lists/*
COPY --from=source /source/ ./
RUN rm -rf .git
COPY --from=source /adapter/ /opt/bundled-plugins/snowluma-adapter/
COPY image/plugins/nuonuo-photo/ /opt/bundled-plugins/nuonuo-photo/
COPY migrate.py /opt/deploy/migrate.py
COPY entrypoint.py /opt/deploy/entrypoint.py
ENV PATH="/opt/maibot/.venv/bin:${PATH}" PYTHONPATH=/opt/maibot PYTHONUTF8=1
LABEL org.opencontainers.image.source="https://github.com/haipengTian/server-ops" \
      org.opencontainers.image.version="1.3.18-qq.1" \
      org.opencontainers.image.licenses="GPL-3.0"
EXPOSE 8001
ENTRYPOINT ["/opt/maibot/.venv/bin/python", "/opt/deploy/entrypoint.py"]
