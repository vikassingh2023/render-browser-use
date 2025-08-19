# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# This is the Dockerfile for browser-use, it bundles the following dependencies:
#     python3, pip, playwright, chromium, browser-use and its dependencies.
# Usage:
#     git clone https://github.com/browser-use/browser-use.git && cd browser-use
#     docker build . -t browseruse --no-cache
#     docker run -v "$PWD/data":/data browseruse
#     docker run -v "$PWD/data":/data browseruse --version
# Multi-arch build:
#     docker buildx create --use
#     docker buildx build . --platform=linux/amd64,linux/arm64--push -t browseruse/browseruse:some-tag
#
# Read more: https://docs.browser-use.com

#########################################################################################


FROM python:3.12-slim

LABEL name="browseruse" \
    maintainer="Nick Sweeting <dockerfile@browser-use.com>" \
    description="Make websites accessible for AI agents. Automate tasks online with ease." \
    homepage="https://github.com/browser-use/browser-use" \
    documentation="https://docs.browser-use.com" \
    org.opencontainers.image.title="browseruse" \
    org.opencontainers.image.vendor="browseruse" \
    org.opencontainers.image.description="Make websites accessible for AI agents. Automate tasks online with ease." \
    org.opencontainers.image.source="https://github.com/browser-use/browser-use" \
    com.docker.image.source.entrypoint="Dockerfile" \
    com.docker.desktop.extension.api.version=">= 1.4.7" \
    com.docker.extension.icon="https://avatars.githubusercontent.com/u/192012301?s=200&v=4" \
    com.docker.extension.publisher-url="https://browser-use.com" \
    com.docker.extension.screenshots='[{"alt": "Screenshot of CLI splashscreen", "url": "https://github.com/user-attachments/assets/3606d851-deb1-439e-ad90-774e7960ded8"}, {"alt": "Screenshot of CLI running", "url": "https://github.com/user-attachments/assets/d018b115-95a4-4ac5-8259-b750bc5f56ad"}]' \
    com.docker.extension.detailed-description='See here for detailed documentation: https://docs.browser-use.com' \
    com.docker.extension.changelog='See here for release notes: https://github.com/browser-use/browser-use/releases' \
    com.docker.extension.categories='web,utility-tools,ai'

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

######### Environment Variables #################################

# Global system-level config
ENV TZ=UTC \
    LANGUAGE=en_US:en \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1 \
    PYTHONIOENCODING=UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_CACHE_DIR=/root/.cache/uv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_PREFERENCE=only-system \
    npm_config_loglevel=error \
    IN_DOCKER=True

# User config
ENV BROWSERUSE_USER="browseruse" \
    DEFAULT_PUID=911 \
    DEFAULT_PGID=911

# Paths
ENV CODE_DIR=/app \
    DATA_DIR=/data \
    VENV_DIR=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

# Build shell config
SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-o", "errtrace", "-o", "nounset", "-c"] 

# Force apt to leave downloaded binaries in /var/cache/apt (massively speeds up Docker builds)
RUN echo 'Binary::apt::APT::Keep-Downloaded-Packages "1";' > /etc/apt/apt.conf.d/99keep-cache \
    && echo 'APT::Install-Recommends "0";' > /etc/apt/apt.conf.d/99no-intall-recommends \
    && echo 'APT::Install-Suggests "0";' > /etc/apt/apt.conf.d/99no-intall-suggests \
    && rm -f /etc/apt/apt.conf.d/docker-clean

# Print debug info about build and save it to disk, for human eyes only, not used by anything else
RUN (echo "[i] Docker build for Browser Use $(cat /VERSION.txt 2>/dev/null || echo 'unknown-version') starting..." \
    && echo "PLATFORM=${TARGETPLATFORM} ARCH=$(uname -m) ($(uname -s) ${TARGETARCH} ${TARGETVARIANT})" \
    && echo "BUILD_START_TIME=$(date +"%Y-%m-%d %H:%M:%S %s") TZ=${TZ} LANG=${LANG}" \
    && echo \
    && echo "CODE_DIR=${CODE_DIR} DATA_DIR=${DATA_DIR} PATH=${PATH}" \
    && echo \
    && uname -a \
    && cat /etc/os-release | head -n7 \
    && which bash && bash --version | head -n1 \
    && which dpkg && dpkg --version | head -n1 \
    && echo -e '\n\n' && env | sort && echo -e '\n\n' \
    && which python && python --version \
    && which pip && pip --version \
    && echo -e '\n\n' \
    ) | tee -a /VERSION.txt

# Create non-privileged user for browseruse and chrome
RUN echo "[*] Setting up $BROWSERUSE_USER user uid=${DEFAULT_PUID}..." \
    && groupadd --system $BROWSERUSE_USER \
    && useradd --system --create-home --gid $BROWSERUSE_USER --groups audio,video $BROWSERUSE_USER \
    && usermod -u "$DEFAULT_PUID" "$BROWSERUSE_USER" \
    && groupmod -g "$DEFAULT_PGID" "$BROWSERUSE_USER" \
    && mkdir -p /data \
    && mkdir -p /home/$BROWSERUSE_USER/.config \
    && chown -R $BROWSERUSE_USER:$BROWSERUSE_USER /home/$BROWSERUSE_USER \
    && ln -s $DATA_DIR /home/$BROWSERUSE_USER/.config/browseruse \
    && echo -e "\nBROWSERUSE_USER=$BROWSERUSE_USER PUID=$(id -u $BROWSERUSE_USER) PGID=$(id -g $BROWSERUSE_USER)\n\n" \
    | tee -a /VERSION.txt
    # DEFAULT_PUID and DEFAULT_PID are overridden by PUID and PGID in /bin/docker_entrypoint.sh at runtime
    # https://docs.linuxserver.io/general/understanding-puid-and-pgid

# Install base apt dependencies (adding backports to access more recent apt updates)
# NOTE: we include python3-dev and build-essential to avoid pip wheel build failures.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-$TARGETARCH$TARGETVARIANT \
    echo "[+] Installing APT base system dependencies for $TARGETPLATFORM..." \
    && mkdir -p /etc/apt/keyrings \
    && apt-get update -qq \
    && apt-get install -qq -y --no-install-recommends \
        # packaging & system utilities
        apt-transport-https ca-certificates apt-utils gnupg2 unzip curl wget grep \
        # debugging helpers
        nano iputils-ping dnsutils jq \
        # build tools for pip wheels if needed
        python3-dev build-essential pkg-config procps \
        # fonts and common deps (useful for browsers)
        fonts-liberation fonts-noto-color-emoji fonts-dejavu-core fonts-freefont-ttf \
        # minimal set of libs for Playwright/browser operation
        libnss3 libnspr4 libatk-bridge2.0-0 libgtk-3-0 libxss1 libasound2 libx11-xcb1 libx11-6 libxcb1 \
        libxcomposite1 libxdamage1 libxrandr2 libgbm1 libatk1.0-0 libcups2 libdrm2 libdbus-1-3 libpangocairo-1.0-0 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy only dependency manifest
WORKDIR /app
COPY pyproject.toml uv.lock* /app/

RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
    echo "[+] Setting up venv using uv in $VENV_DIR..." \
    && ( \
     which uv && uv --version \
     && uv venv \
     && which python | grep "$VENV_DIR" \
     && python --version \
    ) | tee -a /VERSION.txt

# Use Playwright official image for the layer that needs browsers + deps
FROM mcr.microsoft.com/playwright/python:latest AS playwright-base

WORKDIR /app
# Copy only dependency manifest first
COPY pyproject.toml uv.lock* /app/

# Install pip deps (adjust if you use uv/pip sync; here we use pip for simplicity)
RUN pip install --upgrade pip setuptools wheel \
  && pip install patchright \
  && pip install -r <(python - <<'PY'
import tomllib,sys
print("\n".join([])) # If you have requirements, or use poetry/uv adapt accordingly
PY
) || true

# If you rely on uv, create venv etc in this base stage or install things directly

# Final runtime stage based on the same image (keeps browsers present)
FROM mcr.microsoft.com/playwright/python:latest

WORKDIR /app
# Copy installed site-packages from builder if you built inside builder (optional)
# Copy application code
COPY --from=playwright-base /app /app
COPY . /app

# Ensure an unprivileged user is used if desired (the base image may already have one)
USER pwuser

ENTRYPOINT ["bash", "-lc", "browser-use --version || echo 'browser-use not installed'"]

# Install Chromium using playwright and create convenient symlinks
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked,id=apt-$TARGETARCH$TARGETVARIANT \
    --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
    echo "[+] Installing chromium (playwright) and creating symlinks..." \
    && apt-get update -qq \
    && /app/.venv/bin/python -m playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* \
    && export CHROME_BINARY="$(/app/.venv/bin/python -c 'from playwright.sync_api import sync_playwright; print(sync_playwright().start().chromium.executable_path)')" \
    && ln -sf "$CHROME_BINARY" /usr/bin/chromium-browser \
    && ln -sf "$CHROME_BINARY" /app/chromium-browser \
    && mkdir -p "/home/${BROWSERUSE_USER}/.config/chromium/Crash Reports/pending/" \
    && chown -R "$BROWSERUSE_USER:$BROWSERUSE_USER" "/home/${BROWSERUSE_USER}/.config" \
    && ( which chromium-browser && /usr/bin/chromium-browser --version ) | tee -a /VERSION.txt

# Install browser-use python sub-dependencies inside venv
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
     echo "[+] Installing browser-use pip sub-dependencies..." \
     && uv sync --all-extras --no-dev --no-install-project \
     && echo -e '\n\n' | tee -a /VERSION.txt

# Copy the rest of the browser-use codebase
COPY . /app

# Install the browser-use package and all of its optional dependencies using uv (uses the venv)
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT \
     echo "[+] Installing browser-use pip library from source..." \
     && uv sync --all-extras --locked --no-dev \
     && which browser-use \
     && browser-use --version 2>&1 \
     && echo -e '\n\n' | tee -a /VERSION.txt

RUN mkdir -p "$DATA_DIR/profiles/default" \
    && chown -R $BROWSERUSE_USER:$BROWSERUSE_USER "$DATA_DIR" "$DATA_DIR"/* || true \
    && ( \
        echo -e "\n\n[√] Finished Docker build successfully. Saving build summary in: /VERSION.txt" \
        && echo -e "PLATFORM=${TARGETPLATFORM} ARCH=$(uname -m) ($(uname -s) ${TARGETARCH} ${TARGETVARIANT})\n" \
        && echo -e "BUILD_END_TIME=$(date +"%Y-%m-%d %H:%M:%S %s")\n\n" \
    ) | tee -a /VERSION.txt


USER "$BROWSERUSE_USER"
VOLUME "$DATA_DIR"
EXPOSE 9242
EXPOSE 9222

# HEALTHCHECK --interval=30s --timeout=20s --retries=15 \
#     CMD curl --silent 'http://localhost:8000/health/' | grep -q 'OK'

ENTRYPOINT ["browser-use"]
