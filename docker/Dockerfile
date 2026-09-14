# syntax=docker/dockerfile:1
ARG CUDA_VER=12.6.0
ARG UV_EXTRA=cu126
ARG BACKEND=cuda
ARG UBUNTU_VER=24.04
ARG PY_VER=3.12
ARG UV_VERSION=0.8.15

##############################################################
# Base Stage (CUDA)
##############################################################
FROM nvidia/cuda:${CUDA_VER}-cudnn-runtime-ubuntu${UBUNTU_VER} AS base-cuda
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3-pip \
        python3-dev \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

##############################################################
# Base Stage (CPU-only fallback)
##############################################################
FROM python:${PY_VER}-slim AS base-cpu
ENV UV_EXTRA=cpu

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

##############################################################
# UV Binary Stage
##############################################################
ARG UV_VERSION
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin

##############################################################
# Shared App Base
##############################################################
FROM base-${BACKEND} AS app-base

ARG PY_VER
ARG BACKEND
ARG UV_EXTRA

ENV BACKEND=${BACKEND} \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ARG DEPENDENCIES=" \
    libsox-dev \
    build-essential \
    cmake \
    libasound-dev \
    portaudio19-dev \
    libportaudio2 \
    libportaudiocpp0 \
    ffmpeg"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
    && apt-get update \
    && apt-get install -y --no-install-recommends ${DEPENDENCIES} \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv-bin /uv /uvx /bin/

WORKDIR /app
RUN mkdir -p /app/references /app/checkpoints /var/log/runner

# Cache Python dependencies via uv
COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv python pin ${PY_VER} \
    && uv sync --extra ${UV_EXTRA} --frozen --no-install-project

# Copy project source and install editable package
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --extra ${UV_EXTRA} --frozen

##############################################################
# Production Server & Cloud Runner Stage
##############################################################
FROM app-base AS server
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production

# Install Node.js 20.x and system tools for hardware querying
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    pciutils \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install AWS S3 SDK and Node runtime packages
COPY package*.json ./
RUN if [ -f package.json ]; then \
      npm pkg set type="module" && \
      npm install --omit=dev && \
      npm install @aws-sdk/client-s3 @aws-sdk/s3-request-presigner dotenv; \
    else \
      npm init -y && npm pkg set type="module" && \
      npm install @aws-sdk/client-s3 @aws-sdk/s3-request-presigner dotenv; \
    fi

# Copy runner scripts
COPY entrypoint.sh /app/entrypoint.sh
COPY worker.js /app/worker.js

RUN chmod +x /app/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]