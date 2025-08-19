# syntax=docker/dockerfile:1
# browser-use Dockerfile — based on Playwright Python image to avoid manual browser installs

FROM mcr.microsoft.com/playwright/python:latest

LABEL name="browseruse" \
    maintainer="Nick Sweeting <dockerfile@browser-use.com>" \
    description="Make websites accessible for AI agents. Automate tasks online with ease."

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ENV TZ=UTC \
    LANGUAGE=en_US:en \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONIOENCODING=UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_CACHE_DIR=/root/.cache/uv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_PREFERENCE=only-system \
    npm_config_loglevel=error \
    IN_DOCKER=True \
    BROWSERUSE_USER="browseruse" \
    DEFAULT_PUID=911 \
    DEFAULT_PGID=911 \
    CODE_DIR=/app \
    DATA_DIR=/data \
    VENV_DIR=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-o", "errtrace", "-o", "nounset", "-c"]

# Ensure apt cache kept for build caching behavior
RUN echo 'Binary::apt::APT::Keep-Downloaded-Packages "1";' > /etc/apt/apt.conf.d/99keep-cache \
    && echo 'APT::Install-Recommends "0";' > /etc/apt/apt.conf.d/99no-intall-recommends \
    && echo 'APT::Install-Suggests "0";' > /etc/apt/apt.conf.d/99no-intall-suggests \
    && rm -f /etc/apt/apt.conf.d/docker-clean

# Print small debug summary (non-fatal if file missing)
RUN ( \
      echo "[i] Docker build for Browser Use starting..." \
      && echo "PLATFORM=${TARGETPLATFORM} ARCH=$(uname -m) (${TARGETOS:-unknown} ${TARGETARCH:-unknown} ${TARGETVARIANT:-unknown})" \
      && echo "CODE_DIR=${CODE_DIR} DATA_DIR=${DATA_DIR} PATH=${PATH}" \
      && which python || true \
      && python --version || true \
    ) | tee -a /VERSION.txt

# Create non-privileged user and dirs
RUN groupadd --system $BROWSERUSE_USER \
    && useradd --system --create-home --gid $BROWSERUSE_USER --groups audio,video $BROWSERUSE_USER \
    && usermod -u "$DEFAULT_PUID" "$BROWSERUSE_USER" || true \
    && groupmod -g "$DEFAULT_PGID" "$BROWSERUSE_USER" || true \
    && mkdir -p $DATA_DIR /home/$BROWSERUSE_USER/.config \
    && chown -R $BROWSERUSE_USER:$BROWSERUSE_USER /home/$BROWSERUSE_USER \
    && ln -s $DATA_DIR /home/$BROWSERUSE_USER/.config/browseruse

# Install small set of useful packages (playwright image already contains browser deps)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-$TARGETARCH$TARGETVARIANT \
    apt-get update -qq \
    && apt-get install -qq -y --no-install-recommends \
        apt-transport-https ca-certificates curl wget gnupg2 unzip jq iputils-ping nano \
        python3-dev build-essential pkg-config procps fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Copy uv binary from published image so we keep your existing uv workflow
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy only dependency manifest files first to leverage cache
COPY pyproject.toml uv.lock* /app/

# Create virtualenv using uv (keeps parity with upstream)
# Create a Python virtualenv at /app/.venv (avoid using uv venv which may fail in some base images)
RUN set -x \
    && echo "[+] Creating virtualenv at $VENV_DIR (using python -m venv)..." \
    && mkdir -p /app \
    && python -m venv "$VENV_DIR" \
    && test -x "$VENV_DIR/bin/python" \
    && "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel \
    && echo "[+] Virtualenv ready at $VENV_DIR; python: $($VENV_DIR/bin/python --version)" \
    && ln -s "$VENV_DIR/bin" /venv-bin || true \
    && echo "[+] venv created" | tee -a /VERSION.txt

# Use the venv's pip to upgrade tooling and confirm Playwright exists in base image
RUN /app/.venv/bin/python -m pip install --upgrade pip setuptools wheel \
    && echo "[+] Playwright (system) version:" \
    && python -m playwright --version || true

# Install browser-use python sub-dependencies using uv (no Playwright install here — base image already provides browsers)
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
    echo "[+] Installing browser-use pip sub-dependencies..." \
    && uv sync --all-extras --no-dev --no-install-project \
    && echo "[+] sub-deps installed" | tee -a /VERSION.txt

# Copy rest of repository
COPY . /app

# Install browser-use package and all extras inside the venv using uv
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
    echo "[+] Installing browser-use library from source inside venv..." \
    && uv sync --all-extras --locked --no-dev \
    && which browser-use || true \
    && browser-use --version 2>&1 || true \
    && echo "[+] browser-use installed" | tee -a /VERSION.txt

# Create data dirs and set ownership
RUN mkdir -p "$DATA_DIR/profiles/default" \
    && chown -R $BROWSERUSE_USER:$BROWSERUSE_USER "$DATA_DIR" || true \
    && echo "[√] Docker build complete" | tee -a /VERSION.txt

USER "$BROWSERUSE_USER"
VOLUME "$DATA_DIR"
EXPOSE 9242
EXPOSE 9222

ENTRYPOINT ["browser-use"]
