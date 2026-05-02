FROM pytorch/pytorch:2.5.1-cuda12.1-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/app/.hf \
    TRANSFORMERS_CACHE=/app/.hf

RUN apt-get update && apt-get install -y --no-install-recommends \
      espeak-ng \
      libsndfile1 \
      curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Japanese needs the full UniDic dictionary fetched once (~200MB). fugashi
# prefers `unidic` over `unidic-lite` when both are present, and misaki[ja]
# pulls in `unidic`, so without this download the jf_*/jm_* voices fail
# at request time with a MeCab init error.
RUN python -m unidic download

COPY app/ ./app/
COPY scripts/start_kokoro.sh ./scripts/start_kokoro.sh
RUN chmod +x ./scripts/start_kokoro.sh

# Pre-download Kokoro model + phonemizer assets for ALL 9 languages so
# first request in any language is instant.
RUN python -c "from app.engine import preload_all_languages; preload_all_languages()"

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1

# Supervisor restarts uvicorn on crash; logs ship to Axiom when AXIOM_TOKEN
# and AXIOM_DATASET are set in the container env.
CMD ["bash", "/app/scripts/start_kokoro.sh"]
