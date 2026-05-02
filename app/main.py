import logging
import os
import time
from contextlib import asynccontextmanager
from typing import List, Optional

from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field

from app import axiom_handler, phonemizer_patches

logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","lvl":"%(levelname)s","msg":"%(message)s"}',
)
# Ship structured logs to Axiom (no-op if AXIOM_TOKEN/AXIOM_DATASET unset).
axiom_handler.install(service="kokoro-api")
# Patch phonemizer BEFORE engine import — engine pulls in kokoro→misaki→
# phonemizer. See phonemizer_patches.py for the May 2 2026 incident.
phonemizer_patches.apply()

from app.engine import SynthesisResult, get_stats, synthesize, warmup_all_languages

API_TOKEN = os.environ.get("API_TOKEN", "").strip()
if not API_TOKEN:
    raise RuntimeError("API_TOKEN env var is required")

log = logging.getLogger("kokoro-api")

bearer = HTTPBearer(auto_error=True)


def require_auth(creds: HTTPAuthorizationCredentials = Depends(bearer)) -> None:
    if creds.credentials != API_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")


class KokoroRequest(BaseModel):
    model_config = ConfigDict(extra="allow")
    text: str
    preset_voice: Optional[List[str]] = None
    voice: Optional[str] = None
    speed: Optional[float] = 1.0
    output_format: Optional[str] = "pcm"
    return_timestamps: Optional[bool] = True


class WordOut(BaseModel):
    id: int
    start: float
    end: float
    text: str


class InferenceStatus(BaseModel):
    status: str = "succeeded"
    cost: float = 0.0
    runtime_ms: Optional[int] = None
    tokens_input: Optional[int] = None


class KokoroResponse(BaseModel):
    audio: str
    output_format: str = "pcm"
    words: List[WordOut] = Field(default_factory=list)
    inference_status: InferenceStatus = Field(default_factory=InferenceStatus)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    t0 = time.time()
    try:
        warmup_all_languages()
        log.info(f"warmup_done_in_{time.time() - t0:.2f}s")
    except Exception as e:
        log.warning(f"warmup_failed: {e}")
    yield


app = FastAPI(title="kokoro-api", lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/stats", dependencies=[Depends(require_auth)])
def stats():
    return get_stats()


@app.post(
    "/v1/inference/hexgrad/Kokoro-82M",
    dependencies=[Depends(require_auth)],
    response_model=KokoroResponse,
)
def kokoro_inference(req: KokoroRequest) -> KokoroResponse:
    voice: Optional[str] = None
    if req.preset_voice:
        voice = req.preset_voice[0]
    elif req.voice:
        voice = req.voice
    if not voice:
        raise HTTPException(status_code=400, detail="preset_voice or voice is required")

    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    speed = float(req.speed or 1.0)
    t0 = time.perf_counter()
    try:
        result: SynthesisResult
        cache_hit: bool
        result, cache_hit = synthesize(
            text=text,
            voice=voice,
            speed=speed,
            return_timestamps=bool(req.return_timestamps),
        )
    except Exception as e:
        log.exception("synthesis_failed")
        raise HTTPException(status_code=500, detail=f"synthesis_error: {e}") from e
    dt = time.perf_counter() - t0

    log.info(
        f"synth voice={voice} speed={speed} chars={len(text)} "
        f"audio_s={result.duration_seconds:.3f} latency_s={dt:.3f} cache_hit={cache_hit}"
    )

    return KokoroResponse(
        audio=result.audio_pcm16_base64,
        output_format="pcm",
        words=[WordOut(id=w.id, start=w.start, end=w.end, text=w.text) for w in result.words],
        inference_status=InferenceStatus(
            status="succeeded",
            cost=0.0,
            runtime_ms=int(dt * 1000),
            tokens_input=len(text),
        ),
    )
