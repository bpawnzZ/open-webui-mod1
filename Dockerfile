# syntax=docker/dockerfile:1
# Initialize device type args
# use build args in the docker build command with --build-arg="BUILDARG=true"
ARG USE_CUDA=false
ARG USE_OLLAMA=false
# Tested with cu117 for CUDA 11 and cu121 for CUDA 12 (default)
ARG USE_CUDA_VER=cu121
# any sentence transformer model; models to use can be found at https://huggingface.co/models?library=sentence-transformers
# Leaderboard: https://huggingface.co/spaces/mteb/leaderboard 
# for better performance and multilangauge support use "intfloat/multilingual-e5-large" (~2.5GB) or "intfloat/multilingual-e5-base" (~1.5GB)
# IMPORTANT: If you change the embedding model (sentence-transformers/all-MiniLM-L6-v2) and vice versa, you aren't able to use RAG Chat with your previous documents loaded in the WebUI! You need to re-embed them.
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""

# Tiktoken encoding name; models to use can be found at https://huggingface.co/models?library=tiktoken
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"

ARG BUILD_HASH=dev-build
# Override at your own risk - non-root configurations are untested
ARG UID=0
ARG GID=0

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## WebUI backend ########
FROM python:3.11-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID

## SSL Config ##
ENV SSL_CERT_PATH="/app/backend/ssl/cert.pem" \
    SSL_KEY_PATH="/app/backend/ssl/key.pem" \
    USE_SSL="false" \
    SSL_PORT=8443

## Basis ##
ENV ENV=prod \
    PORT=8080 \
    # pass build args to the build
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL}

## Basis URL Config ##
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

## API Key and Security Config ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

#### Other models #########################################################
## whisper TTS model settings ##
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models"

## RAG Embedding model settings ##
ENV RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models"

## Tiktoken model settings ##
ENV TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken"

## Hugging Face download cache ##
ENV HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

ENV HOME=/root
# Create user and group if not root
RUN if [ $UID -ne 0 ]; then \
    if [ $GID -ne 0 ]; then \
    addgroup --gid $GID app; \
    fi; \
    adduser --uid $UID --gid $GID --home $HOME --disabled-password --no-create-home app; \
    fi

RUN mkdir -p $HOME/.cache/chroma
RUN echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id

# Make sure the user has access to the app and root directory
RUN chown -R $UID:$GID /app $HOME

# Install SSL and other dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential pandoc netcat-openbsd curl \
        gcc python3-dev ffmpeg libsm6 libxext6 \
        openssl ca-certificates wget kmod \
        libssl-dev libcurl4-openssl-dev && \
    if [ "$USE_OLLAMA" = "true" ]; then \
    curl -fsSL https://ollama.com/install.sh | sh; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Install Tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bullseye.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bullseye.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && apt-get install -y tailscale && \
    rm -rf /var/lib/apt/lists/*

# Update CA certificates
RUN update-ca-certificates

# SSL Certificate Generation
RUN mkdir -p /app/backend/ssl && \
    openssl req -x509 -newkey rsa:4096 -keyout /app/backend/ssl/key.pem -out /app/backend/ssl/cert.pem \
    -days 365 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName = DNS:localhost,IP:127.0.0.1" && \
    chmod 600 /app/backend/ssl/key.pem && \
    chmod 644 /app/backend/ssl/cert.pem && \
    chown -R $UID:$GID /app/backend/ssl

# Clean pip cache and install pip
RUN python3 -m pip cache purge && \
    python3 -m pip install --upgrade "pip==23.3.2" && \
    python3 -m pip --version

# Install uv and verify installation
RUN python3 -m pip install "uv==0.1.13" && \
    uv --version

# Install torch based on CUDA configuration
RUN if [ "$USE_CUDA" = "true" ]; then \
    python3 -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER --no-cache-dir && \
    python3 -c "import torch; print(torch.__version__); print(torch.cuda.is_available())"; \
    else \
    python3 -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    python3 -c "import torch; print(torch.__version__)"; \
    fi

# Install core dependencies
RUN python3 -m pip install --no-cache-dir \
    tiktoken \
    certifi \
    requests[security] && \
    python3 -c "import tiktoken; print(tiktoken.__version__)"

# Copy backend requirements first
COPY backend/requirements.txt ./backend/requirements.txt

# Install requirements using uv
RUN uv pip install --system -r backend/requirements.txt --no-cache-dir && \
    python3 -c "import pkg_resources; print([pkg.key for pkg in pkg_resources.working_set])"

# Verification steps
RUN python3 -c "import ssl; print(ssl.get_default_verify_paths())" && \
    python3 -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python3 -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python3 -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"

# Set proper permissions
RUN mkdir -p /app/backend/data && \
    chown -R $UID:$GID /app/backend/data

# Create startup script with SSL configuration and TUN module loading
RUN echo '#!/bin/bash\n\
# Attempt to load TUN module\n\
if ! lsmod | grep -q tun; then\n\
    modprobe tun || true\n\
fi\n\
\n\
if [ "$USE_SSL" = "true" ]; then\n\
    echo "Starting server with SSL on port $SSL_PORT"\n\
    exec python3 -m uvicorn main:app --host 0.0.0.0 --port $SSL_PORT --ssl-keyfile=$SSL_KEY_PATH --ssl-certfile=$SSL_CERT_PATH\n\
else\n\
    echo "Starting server without SSL on port $PORT"\n\
    exec python3 -m uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}\n\
fi' > /app/backend/start-with-ssl.sh && \
    chmod +x /app/backend/start-with-ssl.sh

# copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# copy backend files
COPY --chown=$UID:$GID ./backend .

EXPOSE 8080
EXPOSE 8443

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

USER $UID:$GID

ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

CMD [ "bash", "start-with-ssl.sh"]
