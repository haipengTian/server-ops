from io import BytesIO
from pathlib import Path
import base64
import importlib.util
import json
import sys

import httpx
import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from images import ImageAPI, ImageError, normalize_image, preview_data_url


def sample_image():
    buf = BytesIO()
    Image.new("RGB", (64, 96), "blue").save(buf, "PNG")
    return buf.getvalue()


@pytest.mark.asyncio
async def test_portrait_uses_generations_and_life_photo_uses_reference_edit():
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(sample_image()).decode()}]})

    api = ImageAPI("https://images.example/v1", "test-only-key", "gpt-image-2.5-flare", transport=httpx.MockTransport(respond))
    await api.generate("portrait")
    await api.generate("cafe", reference=sample_image())
    assert requests[0].url.path == "/v1/images/generations"
    assert json.loads(requests[0].content)["model"] == "gpt-image-2.5-flare"
    assert requests[1].url.path == "/v1/images/edits"
    assert b'name="image"' in requests[1].content
    assert sample_image() in requests[1].content
    assert b"cafe" in requests[1].content


@pytest.mark.asyncio
async def test_failed_paid_request_is_not_retried_and_does_not_leak_key():
    calls = []

    def respond(request):
        calls.append(request)
        return httpx.Response(403, json={"error": {"message": "secret-test-key is invalid"}})

    api = ImageAPI("https://images.example", "secret-test-key", "gpt-image-2.5-flare", transport=httpx.MockTransport(respond))
    with pytest.raises(ImageError) as exc:
        await api.generate("portrait")
    assert "403" in str(exc.value)
    assert "secret-test-key" not in str(exc.value)
    assert len(calls) == 1


def test_rejects_non_images_and_preserves_image_dimensions():
    with pytest.raises(ImageError):
        normalize_image(b"not an image")
    normalized = normalize_image(sample_image())
    assert Image.open(BytesIO(normalized)).size == (64, 96)


def test_photographic_preview_fits_host_budget():
    buf = BytesIO()
    Image.effect_noise((1024, 1536), 100).convert("RGB").save(buf, "JPEG", quality=95)
    preview = preview_data_url(buf.getvalue())
    assert len(preview) <= 14000
    assert len(json.dumps({"reference": preview, "candidate": preview, "latest": preview}).encode()) < 65536


@pytest.mark.asyncio
async def test_requires_real_image_result():
    api = ImageAPI("https://images.example", "test-key", "gpt-image-2.5-flare", transport=httpx.MockTransport(
        lambda request: httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(b"text").decode()}]})))
    with pytest.raises(ImageError):
        await api.generate("portrait")
