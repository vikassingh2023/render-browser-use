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
        python3-dev python3-venv build-essential pkg-config procps fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Copy uv binary from published image so we keep your existing uv workflow at runtime if needed
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy both dependency manifest and source early so pip install .[extra] works
COPY pyproject.toml uv.lock* /app/
# *** IMPORTANT: copy full source here so pip install . will find package files when installing extras ***
COPY . /app

# Create virtualenv using python -m venv (avoid unreliable uv venv at build-time)
RUN set -x \
    && echo "[+] Creating virtualenv at $VENV_DIR (using python -m venv)..." \
    && mkdir -p /app \
    && python -m venv "$VENV_DIR" \
    && test -x "$VENV_DIR/bin/python" \
    && "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel \
    && echo "[+] Virtualenv ready at $VENV_DIR; python: $($VENV_DIR/bin/python --version)" \
    && ln -sf "$VENV_DIR/bin" /venv-bin || true \
    && echo "[+] venv created" | tee -a /VERSION.txt

# Use the venv's pip to upgrade tooling and confirm Playwright exists in base image
RUN /app/.venv/bin/python -m pip install --upgrade pip setuptools wheel \
    && echo "[+] Playwright (system) version:" \
    && python -m playwright --version || true

# Install python extras declared in pyproject.toml into the venv via a temporary helper script
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT <<'BASH'
set -eux
echo "[+] Installing python extras from pyproject.toml into venv ($VENV_DIR) via pip..."
/app/.venv/bin/python -m pip install --upgrade pip setuptools wheel

# Write a small helper script that reads pyproject.toml and installs extras via pip
cat > /tmp/install_extras.py <<'PY'
import tomllib, sys, subprocess, os, shlex
pt = 'pyproject.toml'
if not os.path.exists(pt):
    print('pyproject.toml not found; skipping extras installation')
    sys.exit(0)
data = tomllib.loads(open(pt, 'rb').read())
extras = []
proj = data.get('project', {})
if proj and proj.get('optional-dependencies'):
    extras = list(proj['optional-dependencies'].keys())
if not extras:
    poetry = data.get('tool', {}).get('poetry', {})
    if poetry and poetry.get('extras'):
        extras = list(poetry['extras'].keys())
if not extras:
    print('No extras found in pyproject.toml; nothing to install')
    sys.exit(0)
print('Discovered extras:', extras)
for ex in extras:
    print('Installing extra:', ex)
    cmd = [sys.executable, '-m', 'pip', 'install', f'.[{ex}]']
    print('Running:', ' '.join(shlex.quote(c) for c in cmd))
    subprocess.check_call(cmd)
print('All extras installed successfully')
PY

# Run the helper inside the venv
/app/.venv/bin/python /tmp/install_extras.py
echo "[+] pip extras install finished" | tee -a /VERSION.txt
BASH

# Install browser-use package and all extras into the venv using pip (avoid uv sync at build-time)
RUN --mount=type=cache,target=/root/.cache,sharing=locked,id=cache-$TARGETARCH$TARGETVARIANT <<'BASH'
set -eux
echo "[+] Installing browser-use package into venv via pip..."
/app/.venv/bin/python -m pip install --upgrade pip setuptools wheel
# Install the package itself
/app/.venv/bin/python -m pip install --no-cache-dir .
which browser-use || true
browser-use --version 2>&1 || true
echo "[+] browser-use installed" | tee -a /VERSION.txt
BASH

# Create data dirs and set ownership
RUN mkdir -p "$DATA_DIR/profiles/d_
