#!/usr/bin/env python3
"""
xvideo_to_telegram_bot — receive an X/Twitter status URL → download the
attached video via yt-dlp → ship it back to the user via Telegram Bot API
sendVideo → delete the local copy.

Single-purpose link-only bot (no slash commands except /start, /help).
Reuses the proven hardening from link-trigger-bot-skeleton.py:
  - httpx.Client with trust_env=False, max_keepalive_connections=0
  - 5-min watchdog rebuild
  - FileHandler logging to ~/.hermes/scripts/xvideo_to_telegram_bot.log
  - ThreadPoolExecutor for the download/send (doesn't block long-poll)
  - editMessageText for live status updates
  - distinct env var XVIDEO_BOT_TOKEN (isolated from WECHAT_BOT_TOKEN, X_BOT_TOKEN)
"""
import os
import re
import sys
import json
import time
import logging
import subprocess
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

log = logging.getLogger("xvideo-bot")

# TOKEN is set by main() at runtime; for unit-test/PoC callers, allow env
# pre-load so the module is usable without going through main().
TOKEN = os.environ.get("XVIDEO_BOT_TOKEN")

# ────────────────────────────────────────────────────────────────
# PATHS
# ────────────────────────────────────────────────────────────────
LOG_FILE = os.path.expanduser(
    os.environ.get("XVIDEO_LOG_FILE", "~/.hermes/scripts/xvideo_to_telegram_bot.log")
)
STAGING_DIR = os.environ.get("XVIDEO_STAGING_DIR", "/tmp/xvideo-dl")

# Telegram Bot API base URL.
# Default: official api.telegram.org (50MB upload cap via sendVideo).
# For 2GB uploads, set BOT_API_BASE_URL=http://localhost:8081 (or your
# local bot-api-server URL) — requires a locally hosted telegram-bot-api
# server with your api_id/api_hash.
API_BASE = os.environ.get("BOT_API_BASE_URL", "https://api.telegram.org")

# ────────────────────────────────────────────────────────────────
# §1 TRIGGER PATTERN — x.com / twitter.com status URLs
# ────────────────────────────────────────────────────────────────
TRIGGER_PATTERN = re.compile(
    r"https?://(?:www\.)?(?:x\.com|twitter\.com)/[A-Za-z0-9_]{1,15}/status/\d{5,25}",
    re.IGNORECASE,
)
URL_RE = re.compile(
    r"(https?://(?:www\.)?(?:x\.com|twitter\.com)/[A-Za-z0-9_]{1,15}/status/\d{5,25})",
    re.IGNORECASE,
)

# ────────────────────────────────────────────────────────────────
# Logging — FileHandler so failures leave a trail even when detached
# ────────────────────────────────────────────────────────────────
Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
_fh = logging.FileHandler(LOG_FILE)
_fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
log.addHandler(_fh)
log.setLevel(logging.INFO)

# Ensure staging dir exists (yt-dlp writes here)
Path(STAGING_DIR).mkdir(parents=True, exist_ok=True)

# ────────────────────────────────────────────────────────────────
# Thread pool — serial = 1 to avoid file collisions and bandwidth contention
# ────────────────────────────────────────────────────────────────
FETCH_POOL = ThreadPoolExecutor(max_workers=1, thread_name_prefix="xvideo-fetch")

# yt-dlp path. macOS launchd can keep using Homebrew; Linux/systemd sets YT_DLP_BIN.
YT_DLP = os.environ.get("YT_DLP_BIN") or os.environ.get("YT_DLP") or "/opt/homebrew/bin/yt-dlp"
CURL = os.environ.get("CURL_BIN", "curl")
FFPROBE = os.environ.get("FFPROBE_BIN", "ffprobe")
UPLOAD_TIMEOUT = int(os.environ.get("XVIDEO_UPLOAD_TIMEOUT", "1800"))
LOCAL_BOT_API_UPLOAD_CAP = float(os.environ.get("XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP", "12"))
TELEGRAM_UPLOAD_EST_MBPS = float(os.environ.get("XVIDEO_TELEGRAM_UPLOAD_EST_MBPS", "0.35"))


# ================================================================
# Telegram helpers — DO NOT MODIFY
# ================================================================

def send_message(client: httpx.Client, chat_id: int, text: str) -> None:
    r = client.post(
        f"{API_BASE}/bot{TOKEN}/sendMessage",
        json={"chat_id": chat_id, "text": text},
        timeout=15,
    )
    if r.status_code != 200:
        log.warning("sendMessage non-200: %s %s", r.status_code, r.text[:200])


def edit_message(client: httpx.Client, chat_id: int, message_id: int, text: str) -> None:
    r = client.post(
        f"{API_BASE}/bot{TOKEN}/editMessageText",
        json={"chat_id": chat_id, "message_id": message_id, "text": text},
        timeout=15,
    )
    if r.status_code != 200:
        log.warning("editMessageText non-200: %s %s", r.status_code, r.text[:200])


def send_video_or_document(client: httpx.Client, chat_id: int, filepath: str, caption: str = "") -> None:
    """
    Upload a local video file to Telegram as a real video message.

    Kept for callers/tests that still use the old helper name. The actual
    implementation is sendVideo via curl, with video/mp4 MIME and metadata.
    """
    _upload_video_with_progress(chat_id, filepath, caption, progress=None)


# ================================================================
# §2 FETCH PIPELINE — download + send + cleanup
# ================================================================

def _cleanup(filepath: str) -> None:
    """Best-effort delete of staged file. Failures logged, never raised."""
    try:
        if filepath and os.path.isfile(filepath):
            os.remove(filepath)
            log.info("deleted staged file: %s", filepath)
    except Exception as e:
        log.warning("cleanup failed for %s: %s", filepath, e)


def _cleanup_job_files(job_prefix: str | None) -> None:
    """Best-effort delete of all files created for one yt-dlp job."""
    if not job_prefix:
        return
    for p in Path(STAGING_DIR).glob(f"{job_prefix}-*"):
        try:
            if p.is_file():
                p.unlink()
                log.info("deleted staged job file: %s", p)
        except Exception as e:
            log.warning("cleanup failed for %s: %s", p, e)


# ================================================================
# Progress parsing + formatting
# ================================================================

# yt-dlp --newline stdout progress line (one per update):
#   "[download]  42.3% of ~294.50MiB at 2.10MiB/s ETA 00:01:23"
# We capture the LAST seen progress and render it on edit_message ticks.
_YT_DLP_PROGRESS_RE = re.compile(
    r"\[download\]\s+(?P<pct>\d+(?:\.\d+)?)%\s+of\s+~?\s*(?P<size>[\d.]+\s*\S+)"
    r"(?:\s+at\s+(?P<speed>[\d.]+\s*\S+))?"
    r"(?:\s+ETA\s+(?P<eta>\S+))?"
)
_YT_DLP_DEST_RE = re.compile(r"\[download\]\s+Destination:\s+(.+)$")
_YT_DLP_PROGRESS_PREFIX = "XVT_PROGRESS\t"
_YT_DLP_PROGRESS_TEMPLATE = (
    "download:XVT_PROGRESS\t%(progress.status)s\t%(progress._percent_str)s\t"
    "%(progress._total_bytes_str)s\t%(progress._total_bytes_estimate_str)s\t"
    "%(progress._speed_str)s\t%(progress._eta_str)s\t%(progress.filename|)s\t"
    "%(progress.tmpfilename|)s\t%(info.format_id|)s\t%(info.ext|)s\t"
    "%(info.vcodec|)s\t%(info.acodec|)s"
)

# curl --progress-bar line:
#   "##########              24.3%  5.2M   0:00:04  0:00:12 1.2M"
# curl writes updates with \r, so the stderr reader splits on \r and \n.
_CURL_PROGRESS_RE = re.compile(
    r"(?P<pct>\d+(?:\.\d+)?)\s*%"
)
_AUDIO_EXTS = {".aac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav", ".weba"}


def _format_size_mb(n_bytes: int) -> str:
    return f"{n_bytes / 1024 / 1024:.1f} MB"


def _format_elapsed(seconds: float) -> str:
    seconds = max(0, int(seconds))
    mins, secs = divmod(seconds, 60)
    hours, mins = divmod(mins, 60)
    if hours:
        return f"{hours:d}:{mins:02d}:{secs:02d}"
    return f"{mins:d}:{secs:02d}"


def _clamp(n: float, low: float, high: float) -> float:
    return max(low, min(high, n))


def _local_upload_cap_pct() -> float:
    return _clamp(LOCAL_BOT_API_UPLOAD_CAP, 3.0, 35.0)


def _estimate_telegram_upload_seconds(size_bytes: int) -> float:
    size_mb = max(0.1, size_bytes / 1024 / 1024)
    mbps = TELEGRAM_UPLOAD_EST_MBPS if TELEGRAM_UPLOAD_EST_MBPS > 0 else 0.35
    # The local Bot API accepts the request quickly, then uploads to Telegram.
    # This is an estimate for UI pacing only; Telegram does not expose this progress.
    return _clamp(20.0 + size_mb / mbps, 25.0, UPLOAD_TIMEOUT * 0.9)


def _parse_percent(text: str) -> float | None:
    m = _CURL_PROGRESS_RE.search(text or "")
    if not m:
        return None
    return max(0.0, min(100.0, float(m.group("pct"))))


def _parse_yt_dlp_line(line: str) -> dict | None:
    """Parse a single yt-dlp --newline progress line. Returns dict or None."""
    m = _YT_DLP_PROGRESS_RE.search(line)
    if not m:
        return None
    return {
        "pct": float(m.group("pct")),
        "size_str": m.group("size"),
        "speed_str": m.group("speed") or "",
        "eta_str": m.group("eta") or "",
    }


def _parse_yt_dlp_progress_template(line: str) -> dict | None:
    """Parse the machine-readable progress line emitted by --progress-template."""
    if not line.startswith(_YT_DLP_PROGRESS_PREFIX):
        return None
    parts = line.rstrip("\n").split("\t")
    parts.extend([""] * (13 - len(parts)))
    pct = _parse_percent(parts[2])
    if pct is None:
        return None

    size_str = parts[3].strip()
    if not size_str or size_str == "N/A":
        size_str = parts[4].strip()
    if size_str == "NA":
        size_str = ""

    speed_str = parts[5].strip()
    if speed_str in ("NA", "Unknown B/s"):
        speed_str = ""
    eta_str = parts[6].strip()
    if eta_str in ("NA", "Unknown"):
        eta_str = ""

    extra_parts = []
    if speed_str:
        extra_parts.append(f"🚀 {speed_str}")
    if eta_str:
        extra_parts.append(f"⏱ ETA {eta_str}")

    return {
        "status": parts[1].strip(),
        "pct": pct,
        "size_str": size_str,
        "extra": " · ".join(extra_parts),
        "filename": parts[7].strip(),
        "tmpfilename": parts[8].strip(),
        "format_id": parts[9].strip(),
        "ext": parts[10].strip(),
        "vcodec": parts[11].strip(),
        "acodec": parts[12].strip(),
    }


def _classify_download_stream(progress: dict) -> str | None:
    """Return 'video', 'audio', or None for a yt-dlp progress event."""
    filename = (progress.get("filename") or "").lower()
    tmpfilename = (progress.get("tmpfilename") or "").lower()
    format_id = (progress.get("format_id") or "").lower()
    ext = (progress.get("ext") or "").lower().lstrip(".")
    vcodec = (progress.get("vcodec") or "").lower()
    acodec = (progress.get("acodec") or "").lower()
    haystack = " ".join([filename, tmpfilename, format_id, ext])

    if vcodec == "none" or f".{ext}" in _AUDIO_EXTS or "audio" in haystack:
        return "audio"
    if acodec == "none" or (vcodec and vcodec not in ("none", "na")):
        return "video"
    if any(token in haystack for token in (".m4a", ".mp3", ".opus", ".weba", "-audio", "faudio")):
        return "audio"
    return None


def _classify_destination(path: str, seen_count: int) -> str | None:
    basename = os.path.basename(path).lower()
    ext = Path(basename).suffix.lower()
    if ext in _AUDIO_EXTS or "audio" in basename or "faudio" in basename:
        return "audio"
    if seen_count == 1:
        return "video"
    return None


def _parse_curl_progress_line(line: str) -> float | None:
    pct = _parse_percent(line)
    if pct is not None:
        return pct
    stripped = line.strip()
    if stripped and set(stripped) == {"#"}:
        return min(100.0, len(stripped) / 72 * 100)
    return None


class ProgressReporter:
    """
    Tracks latest progress from a subprocess stream and throttles
    edit_message calls so we don't hammer Telegram's rate limits.

    Telegram limits:
      - editMessageText on the same message: ~30/min
      - sendMessage: ~30/min total per bot
    We update at most every UPDATE_INTERVAL seconds.

    IMPORTANT: uses its OWN httpx.Client (separate from the polling loop's
    client). Reason: httpx.Client is single-connection by default. The
    polling loop holds the connection in a 30s long-poll — any edit_message
    call on the same client blocks until that long-poll returns. With our
    own client, edit_message calls complete in <100ms.
    """

    UPDATE_INTERVAL = 5.0  # seconds between edit_message calls

    def __init__(self, chat_id, msg_id, label_emoji="⏳", label_phase=""):
        self.chat_id = chat_id
        self.msg_id = msg_id
        self.label_emoji = label_emoji
        self.label_phase = label_phase  # e.g. "下载视频", "下载音频", "上传到 Telegram"
        self._lock = threading.Lock()
        self.last_text = None
        self.last_edit_at = 0.0
        self.latest_pct = 0.0
        self.latest_extra = ""
        self.latest_size_str = ""
        # Independent client — see class docstring
        self._client = httpx.Client(
            timeout=15.0,
            limits=httpx.Limits(max_keepalive_connections=0, max_connections=1),
            trust_env=False,
        )

    def set_phase(self, new_phase: str, *, reset_pct: bool = True) -> None:
        """Update label_phase and reset pct so UI shows the new stage cleanly."""
        with self._lock:
            if new_phase != self.label_phase:
                self.label_phase = new_phase
                if reset_pct:
                    self.latest_pct = 0.0
                    self.latest_size_str = ""
                    self.latest_extra = ""
                self.last_text = None
                self.last_edit_at = 0.0

    def update(self, pct: float, size_str: str = "", extra: str = "", *, force: bool = False) -> None:
        """Called from the stream reader thread on every progress event."""
        with self._lock:
            self.latest_pct = max(0.0, min(100.0, pct))
            if size_str:
                self.latest_size_str = size_str
            self.latest_extra = extra
            now = time.monotonic()
            if not force and now - self.last_edit_at < self.UPDATE_INTERVAL:
                return
        log.info("progress: %s %.1f%% %s — calling edit_message",
                 self.label_phase, pct, size_str)
        self._flush()

    def _flush(self) -> None:
        # Build a clean single-message status with a progress bar
        with self._lock:
            bar_len = 20
            filled = int(self.latest_pct / 100 * bar_len)
            bar = "█" * filled + "░" * (bar_len - filled)
            lines = [
                f"{self.label_emoji} {self.label_phase}… {self.latest_pct:5.1f}%",
                f"[{bar}]",
            ]
            if self.latest_size_str:
                lines.append(f"📦 {self.latest_size_str}")
            if self.latest_extra:
                lines.append(self.latest_extra)
            text = "\n".join(lines)
            if text == self.last_text:
                return  # no change
            self.last_text = text
        try:
            edit_message(self._client, self.chat_id, self.msg_id, text)
            with self._lock:
                self.last_edit_at = time.monotonic()
        except Exception as e:
            log.warning("edit_message (progress) failed: %s", e)

    def close(self) -> None:
        """Release the underlying httpx.Client."""
        try:
            self._client.close()
        except Exception:
            pass


def _probe_video_metadata(filepath: str) -> dict[str, int]:
    """Best-effort ffprobe metadata for Telegram sendVideo preview fields."""
    try:
        result = subprocess.run(
            [
                FFPROBE, "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height:format=duration",
                "-of", "json",
                filepath,
            ],
            capture_output=True, text=True, timeout=20,
        )
        if result.returncode != 0:
            log.warning("ffprobe failed for %s: %s", filepath, result.stderr[:200])
            return {}
        data = json.loads(result.stdout or "{}")
        stream = (data.get("streams") or [{}])[0]
        fmt = data.get("format") or {}
        meta: dict[str, int] = {}
        for key in ("width", "height"):
            value = stream.get(key)
            if isinstance(value, int) and value > 0:
                meta[key] = value
        try:
            duration = int(round(float(fmt.get("duration") or 0)))
            if duration > 0:
                meta["duration"] = duration
        except (TypeError, ValueError):
            pass
        return meta
    except FileNotFoundError:
        log.warning("ffprobe binary not found: %s", FFPROBE)
        return {}
    except Exception as e:
        log.warning("ffprobe metadata failed for %s: %s", filepath, e)
        return {}


def _build_send_video_curl_cmd(chat_id: int, filepath: str, caption: str = "") -> list[str]:
    metadata = _probe_video_metadata(filepath)
    cmd = [
        CURL,
        "--show-error", "--fail-with-body", "--progress-bar",
        "--max-time", str(UPLOAD_TIMEOUT),
        "--connect-timeout", "30",
        "-X", "POST",
        f"{API_BASE}/bot{TOKEN}/sendVideo",
        "-F", f"chat_id={chat_id}",
        "-F", f"video=@{filepath};type=video/mp4",
        "-F", "supports_streaming=true",
    ]
    if caption:
        cmd.extend(["-F", f"caption={caption[:1024]}"])
    for key in ("duration", "width", "height"):
        value = metadata.get(key)
        if value:
            cmd.extend(["-F", f"{key}={value}"])
    return cmd


def _extract_last_json(text: str) -> dict | None:
    decoder = json.JSONDecoder()
    last_obj = None
    for match in re.finditer(r"\{", text or ""):
        try:
            obj, _ = decoder.raw_decode(text[match.start():])
            if isinstance(obj, dict) and "ok" in obj:
                return obj
            last_obj = obj
        except json.JSONDecodeError:
            continue
    return last_obj if isinstance(last_obj, dict) else None


def _upload_video_with_progress(
    chat_id: int,
    filepath: str,
    caption: str = "",
    progress: ProgressReporter | None = None,
) -> dict | None:
    p = Path(filepath)
    if not p.is_file():
        raise FileNotFoundError(f"sendVideo: {filepath} missing")
    size = p.stat().st_size
    TWO_GB = 2 * 1024 * 1024 * 1024
    if size > TWO_GB:
        raise ValueError(f"file too large for Telegram: {size} bytes (>2GB)")

    size_mb = size / 1024 / 1024
    if "api.telegram.org" in API_BASE and size_mb > 49:
        raise ValueError(
            f"video too large for official Bot API: {size_mb:.1f} MB > 50 MB. "
            "Need BOT_API_BASE_URL pointing at a local Bot API server."
        )

    log.info("sendVideo uploading %s (%d bytes / %.1f MB) to chat %s",
             p.name, size, size_mb, chat_id)
    if progress:
        progress.set_phase("提交到本地 Bot API")
        progress.update(0.0, size_str=_format_size_mb(size), force=True)

    cmd = _build_send_video_curl_cmd(chat_id, filepath, caption)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    response_chunks: list[str] = []
    stderr_notes: list[str] = []
    local_cap_pct = _local_upload_cap_pct()
    state_lock = threading.Lock()
    local_upload_done_at: float | None = None
    last_local_display_pct = 0.0
    last_estimated_tg_pct = local_cap_pct

    def update_local_submit_progress(raw_pct: float) -> None:
        nonlocal last_local_display_pct, local_upload_done_at
        displayed_pct = _clamp(raw_pct / 100 * local_cap_pct, 0.0, local_cap_pct)
        with state_lock:
            if displayed_pct < last_local_display_pct:
                displayed_pct = last_local_display_pct
            last_local_display_pct = displayed_pct
            already_done = local_upload_done_at is not None
            if raw_pct >= 99.9 and not already_done:
                local_upload_done_at = time.monotonic()
        if not progress:
            return
        if raw_pct >= 99.9 and not already_done:
            progress.set_phase("Telegram 上传处理中", reset_pct=False)
            progress.update(
                local_cap_pct,
                size_str=_format_size_mb(size),
                extra="本地提交完成，等待 Telegram 接收",
                force=True,
            )
        elif not already_done:
            progress.update(
                displayed_pct,
                size_str=_format_size_mb(size),
                extra="正在提交到本地 Bot API",
            )

    def stdout_reader() -> None:
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            response_chunks.append(chunk)

    def handle_stderr_segment(segment: str) -> None:
        line = segment.strip()
        if not line:
            return
        pct = _parse_curl_progress_line(line)
        if pct is not None:
            update_local_submit_progress(pct)
            return
        stderr_notes.append(line)
        if len(stderr_notes) > 20:
            del stderr_notes[:-20]

    def stderr_reader() -> None:
        assert proc.stderr is not None
        buf = []
        while True:
            ch = proc.stderr.read(1)
            if not ch:
                break
            if ch in ("\r", "\n"):
                handle_stderr_segment("".join(buf))
                buf.clear()
            else:
                buf.append(ch)
        if buf:
            handle_stderr_segment("".join(buf))

    t_out = threading.Thread(target=stdout_reader, daemon=True)
    t_err = threading.Thread(target=stderr_reader, daemon=True)
    t_out.start()
    t_err.start()

    started = time.monotonic()
    last_wait_update = 0.0
    while True:
        rc = proc.poll()
        if rc is not None:
            break
        now = time.monotonic()
        if progress and now - last_wait_update >= ProgressReporter.UPDATE_INTERVAL:
            with state_lock:
                done_at = local_upload_done_at
            elapsed_total = _format_elapsed(now - started)
            if done_at is None and now - started >= 8:
                with state_lock:
                    if local_upload_done_at is None:
                        local_upload_done_at = now
                    done_at = local_upload_done_at
                progress.set_phase("Telegram 上传处理中", reset_pct=False)
                progress.update(
                    max(local_cap_pct, last_local_display_pct),
                    size_str=_format_size_mb(size),
                    extra="本地提交已完成，等待 Telegram 接收",
                    force=True,
                )
            if done_at is not None:
                telegram_elapsed = now - done_at
                estimate = _estimate_telegram_upload_seconds(size)
                estimated_pct = local_cap_pct + (95.0 - local_cap_pct) * min(1.0, telegram_elapsed / estimate)
                if estimated_pct < last_estimated_tg_pct:
                    estimated_pct = last_estimated_tg_pct
                last_estimated_tg_pct = estimated_pct
                if estimated_pct >= 95.0:
                    extra = f"等待 Telegram 最终确认 · 已用时 {elapsed_total}"
                else:
                    extra = f"Telegram 上传中 · 已用时 {elapsed_total}"
                progress.update(estimated_pct, size_str=_format_size_mb(size), extra=extra)
            else:
                progress.update(
                    max(last_local_display_pct, 1.0),
                    size_str=_format_size_mb(size),
                    extra=f"正在提交到本地 Bot API · 已用时 {elapsed_total}",
                )
            last_wait_update = now
        if now - started > UPLOAD_TIMEOUT + 5:
            proc.kill()
            proc.wait()
            raise subprocess.TimeoutExpired(cmd, UPLOAD_TIMEOUT)
        time.sleep(0.5)

    t_out.join(timeout=10)
    t_err.join(timeout=10)
    elapsed = time.monotonic() - started
    body_text = "".join(response_chunks)

    if progress:
        progress.update(100.0, size_str=_format_size_mb(size), extra="✅ Telegram 已接收", force=True)

    if proc.returncode != 0:
        err = "\n".join(stderr_notes) or body_text.strip()
        raise RuntimeError(
            f"sendVideo curl exit={proc.returncode} after {elapsed:.1f}s: {err[:500]}"
        )

    body = _extract_last_json(body_text)
    if body and not body.get("ok"):
        raise RuntimeError(f"sendVideo ok=false: {body}")

    log.info("sendVideo OK: %s (%d bytes / %.1f MB) in %.1fs",
             p.name, size, size_mb, elapsed)
    return body


def fetch_and_save(url: str, chat_id: int, status_msg_id: int, client: httpx.Client) -> None:
    """
    Download X video → upload to Telegram → delete local copy.

    Status message evolution (one message, edited in place):
      ⏳ 解析视频...
      ⬇️ 下载视频... 42.3% [bar] 📦 294MB
      ⬇️ 下载音频... 42.3% [bar] 📦 24MB
      ⏳ 上传到 Telegram... 67.0% [bar]
      ✅ 已发送 ...
    """
    staged_file: str | None = None
    job_prefix: str | None = None
    dl_progress: ProgressReporter | None = None
    up_progress: ProgressReporter | None = None
    try:
        # Step 1 — quick format probe to confirm there's a video
        edit_message(client, chat_id, status_msg_id, f"⏳ 解析视频…\n{url}")
        probe = subprocess.run(
            [YT_DLP, "--no-warnings", "--no-update", "-F", url],
            capture_output=True, text=True, timeout=60,
        )
        if probe.returncode != 0 or "Available formats" not in probe.stdout:
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 没找到视频或解析失败\n{url}\n\n{probe.stderr.strip()[:200]}")
            log.warning("probe failed for %s: %s", url, probe.stderr[:200])
            return

        # Step 2 — download with progress reporting
        job_prefix = f"{int(time.time())}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
        out_tmpl = os.path.join(STAGING_DIR, f"{job_prefix}-%(id)s.%(ext)s")
        dl_progress = ProgressReporter(
            chat_id, status_msg_id,
            label_emoji="⬇️", label_phase="下载视频",
        )
        # Step 4 — upload to Telegram with progress reporting
        up_progress = ProgressReporter(
            chat_id, status_msg_id,
            label_emoji="⬆️", label_phase="上传到 Telegram",
        )

        phase_lock = threading.Lock()
        seen_destinations = 0
        last_download_pct: float | None = None
        dl_error_lines: list[str] = []

        def switch_download_phase(kind: str, reason: str) -> None:
            if kind == "audio":
                if dl_progress.label_phase != "下载音频":
                    dl_progress.set_phase("下载音频")
                    log.info("phase switched to 下载音频 (%s)", reason)
            elif kind == "video" and dl_progress.label_phase != "下载音频":
                dl_progress.set_phase("下载视频")

        def handle_ytdlp_line(line: str, stream_name: str) -> bool:
            nonlocal seen_destinations, last_download_pct
            parsed_template = _parse_yt_dlp_progress_template(line)
            if parsed_template:
                kind = _classify_download_stream(parsed_template)
                pct = parsed_template["pct"]
                with phase_lock:
                    if kind:
                        switch_download_phase(kind, f"{stream_name} progress")
                    elif (
                        dl_progress.label_phase == "下载视频"
                        and last_download_pct is not None
                        and last_download_pct >= 75.0
                        and pct <= 25.0
                        and last_download_pct - pct >= 50.0
                    ):
                        switch_download_phase("audio", "progress restarted after video")
                    last_download_pct = pct
                dl_progress.update(
                    pct=pct,
                    size_str=parsed_template["size_str"],
                    extra=parsed_template["extra"],
                )
                return True

            m_dest = _YT_DLP_DEST_RE.search(line)
            if m_dest:
                with phase_lock:
                    seen_destinations += 1
                    kind = _classify_destination(m_dest.group(1), seen_destinations)
                    if kind:
                        switch_download_phase(kind, f"{stream_name} destination #{seen_destinations}")
                return True

            parsed_default = _parse_yt_dlp_line(line)
            if parsed_default:
                pct = parsed_default["pct"]
                extra_parts = []
                if parsed_default["speed_str"]:
                    extra_parts.append(f"🚀 {parsed_default['speed_str']}")
                if parsed_default["eta_str"] and parsed_default["eta_str"] != "Unknown":
                    extra_parts.append(f"⏱ ETA {parsed_default['eta_str']}")
                with phase_lock:
                    if (
                        dl_progress.label_phase == "下载视频"
                        and last_download_pct is not None
                        and last_download_pct >= 75.0
                        and pct <= 25.0
                        and last_download_pct - pct >= 50.0
                    ):
                        switch_download_phase("audio", "progress restarted after video")
                    last_download_pct = pct
                dl_progress.update(
                    pct=pct,
                    size_str=parsed_default["size_str"],
                    extra=" · ".join(extra_parts),
                )
                return True

            if stream_name == "stderr" and line.strip():
                dl_error_lines.append(line.strip())
                if len(dl_error_lines) > 20:
                    del dl_error_lines[:-20]
            return False

        # --progress-template gives us stable tab-separated progress fields,
        # including the current temp filename/format when yt-dlp downloads
        # video and audio streams separately.
        dl_proc = subprocess.Popen(
            [
                YT_DLP, "--no-warnings", "--no-update", "--newline",
                "--color", "no_color",
                "--progress-template", _YT_DLP_PROGRESS_TEMPLATE,
                "--progress-delta", "0.5",
                "-f", "bv*[height<=720][ext=mp4]+ba[ext=m4a]/bv*[height<=720]+ba/best",
                "--merge-output-format", "mp4",
                "--remux-video", "mp4",
                "-o", out_tmpl,
                url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )

        def dl_reader(stream, stream_name: str):
            log.info("dl_%s_reader thread started", stream_name)
            line_count = 0
            progress_count = 0
            for line in stream:
                line = line.rstrip("\n")
                line_count += 1
                if handle_ytdlp_line(line, stream_name):
                    progress_count += 1
            log.info("dl_%s_reader done; %d lines total, %d handled updates",
                     stream_name, line_count, progress_count)

        t = threading.Thread(target=dl_reader, args=(dl_proc.stdout, "stdout"), daemon=True)
        t.start()
        t_err = threading.Thread(target=dl_reader, args=(dl_proc.stderr, "stderr"), daemon=True)
        t_err.start()

        try:
            dl_proc.wait(timeout=600)
        except subprocess.TimeoutExpired:
            dl_proc.kill()
            dl_proc.wait()
            raise
        # Give the reader threads time to drain remaining pipe data
        # (process exited but there might be a final batch in the pipes)
        t.join(timeout=10)
        t_err.join(timeout=10)

        dl_progress._flush()  # final progress state

        if dl_proc.returncode != 0:
            err_text = "\n".join(dl_error_lines)[-500:]
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 下载失败\n{url}" + (f"\n\n{err_text[:300]}" if err_text else ""))
            log.warning("download failed for %s (rc=%d): %s",
                        url, dl_proc.returncode, err_text)
            return

        # Step 3 — locate the downloaded file by this job's unique prefix.
        files = sorted(
            (
                p for p in Path(STAGING_DIR).glob(f"{job_prefix}-*.mp4")
                if p.is_file() and not p.name.endswith(".part")
            ),
            key=lambda p: (p.stat().st_size, p.stat().st_mtime),
            reverse=True,
        )
        staged_file = str(files[0]) if files else None

        if not staged_file or not os.path.isfile(staged_file):
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 找不到下载产物\n{url}")
            log.error("no staged file after dl for %s (candidates=%d)",
                      url, len(files))
            return

        size_bytes = os.path.getsize(staged_file)
        size_mb = size_bytes / 1024 / 1024
        log.info("downloaded %s -> %s (%d bytes)", url, staged_file, size_bytes)

        # Step 3.5 — Telegram upload limit check.
        # Official api.telegram.org caps sendVideo at ~50MB.
        # Local bot-api-server (BOT_API_BASE_URL != api.telegram.org) raises
        # this to 2GB. With sendVideo the file shows up as a video with
        # inline preview, not a flat document attachment.
        size_mb_for_limit = size_bytes / 1024 / 1024
        if "api.telegram.org" in API_BASE and size_mb_for_limit > 49:
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 视频太大 ({size_mb_for_limit:.1f} MB > 49 MB)\n"
                         f"官方 Bot API 上限 50MB。需要部署本地 Bot API server "
                         f"(BOT_API_BASE_URL) 才能突破到 2GB。\n"
                         f"🔗 {url}")
            log.warning("file too large for official Bot API: %.1f MB (need local server)",
                        size_mb_for_limit)
            return

        # Step 4 — upload to Telegram with progress reporting.
        caption = f"🎬 X 视频\n🔗 {url}\n💾 {size_mb:.1f} MB"
        _upload_video_with_progress(chat_id, staged_file, caption, up_progress)

        # Step 5 — done
        edit_message(client, chat_id, status_msg_id,
                     f"✅ 已发送\n🎬 {Path(staged_file).name} ({size_mb:.1f} MB)\n🔗 {url}")
        log.info("delivered %s to chat %s", url, chat_id)

    except subprocess.TimeoutExpired:
        log.warning("timeout for %s", url)
        try:
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 超时（可能是大文件）\n{url}")
        except Exception:
            pass
    except Exception as e:
        log.exception("fetch_and_save crashed for %s: %s", url, e)
        try:
            edit_message(client, chat_id, status_msg_id,
                         f"❌ 内部错误\n{type(e).__name__}: {e}")
        except Exception:
            pass
    finally:
        if job_prefix:
            _cleanup_job_files(job_prefix)
        elif staged_file:
            _cleanup(staged_file)
        # Release progress clients
        try:
            dl_progress.close()
        except Exception:
            pass
        try:
            up_progress.close()
        except Exception:
            pass


# ================================================================
# Message handler — trigger detection + ack + dispatch
# ================================================================

def handle_message(msg: dict, client: httpx.Client) -> None:
    chat_id = msg.get("chat", {}).get("id")
    if not chat_id:
        return
    text = (msg.get("text") or "").strip()
    if not text:
        return

    # Slash commands — only /start and /help for one-time discoverability
    if text.startswith("/"):
        cmd = text.split()[0].split("@")[0].lower()
        if cmd in ("/start", "/help"):
            HELP_TEXT = (
                "👋 我把 X (Twitter) 推文里的视频下载下来发给你。\n"
                "用法：直接把推文链接发给我（比如 https://x.com/<user>/status/<id>）。\n"
                "其他消息我安静忽略。\n\n"
                "🎬 通过 sendVideo 发送 — 在聊天里显示视频预览。\n"
                "📦 本地 Bot API 服务下最大 2GB。\n"
                "⏳ 视频大时可能要等几分钟。"
            )
            send_message(client, chat_id, HELP_TEXT)
        return

    # Trigger detection
    m = URL_RE.search(text)
    if not m:
        return
    url = m.group(1).rstrip(".,;:!?)]}\"'<>")

    # Ack — capture message_id so worker can edit it
    ack = client.post(
        f"{API_BASE}/bot{TOKEN}/sendMessage",
        json={"chat_id": chat_id, "text": f"⏳ 收到链接，准备下载…\n{url}"},
        timeout=15,
    )
    try:
        status_msg_id = ack.json()["result"]["message_id"]
    except Exception:
        log.warning("could not get status message_id; ack=%s", ack.text[:200])
        return

    FETCH_POOL.submit(fetch_and_save, url, chat_id, status_msg_id, client)


# ================================================================
# Polling loop — DO NOT MODIFY
# ================================================================

def run_polling_loop(token: str, depth: int = 0) -> int:
    if depth >= 5:
        log.error("run_polling_loop recursion limit reached (5); giving up")
        return 2
    offset: int | None = None
    url_get = f"{API_BASE}/bot{token}/getUpdates"
    timeout_sec = 30
    backoff = 2
    poll_limits = httpx.Limits(max_keepalive_connections=0, max_connections=4)
    with httpx.Client(
        timeout=timeout_sec + 5, limits=poll_limits, trust_env=False,
    ) as client:
        me = client.get(f"{API_BASE}/bot{token}/getMe", timeout=10).json()
        if not me.get("ok"):
            log.error("getMe failed: %s", me)
            return 1
        log.info(
            "Bot online: @%s (id=%s) — x.com link → video → Telegram",
            me["result"].get("username"),
            me["result"].get("id"),
        )

        last_ok = time.monotonic()
        watchdog_rebuilds = 0
        WATCHDOG_STALE = 300  # 5 min

        while True:
            try:
                params = {"timeout": timeout_sec, "allowed_updates": json.dumps(["message"])}
                if offset is not None:
                    params["offset"] = offset
                r = client.get(url_get, params=params, timeout=timeout_sec + 10)
                last_ok = time.monotonic()  # ONLY successful response resets watchdog
                if r.status_code == 409:
                    log.error("409 Conflict — another instance owns this token. Sleeping 60s.")
                    time.sleep(60)
                    continue
                if r.status_code == 502:
                    time.sleep(5)
                    continue
                if r.status_code != 200:
                    log.warning("getUpdates HTTP %s: %s", r.status_code, r.text[:200])
                    time.sleep(backoff)
                    backoff = min(backoff * 2, 30)
                    continue
                backoff = 2
                data = r.json()
                if not data.get("ok"):
                    log.warning("getUpdates not ok: %s", data)
                    time.sleep(backoff)
                    continue
                for upd in data.get("result", []):
                    offset = upd["update_id"] + 1
                    msg = upd.get("message")
                    if msg:
                        try:
                            handle_message(msg, client)
                        except Exception as e:
                            log.exception("handle_message error: %s", e)
                if time.monotonic() - last_ok > WATCHDOG_STALE:
                    raise RuntimeError("watchdog: stale, rebuilding client")
            except httpx.TimeoutException:
                log.debug("long-poll timeout (no updates) — fine")
                continue
            except httpx.HTTPError as e:
                log.warning("HTTP error: %s; sleeping %ss", e, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)
                # NOTE: do NOT reset last_ok here — let the watchdog catch this
            except (RuntimeError, Exception) as e:
                if "watchdog" in str(e):
                    watchdog_rebuilds += 1
                    log.warning(
                        "watchdog triggered (%d rebuilds): %s — rebuilding",
                        watchdog_rebuilds, e,
                    )
                    try:
                        client.close()
                    except Exception:
                        pass
                    return run_polling_loop(token, depth=depth + 1)
                raise
            except KeyboardInterrupt:
                log.info("Stopped by user")
                return 0


def main() -> int:
    global TOKEN
    TOKEN = os.environ.get("XVIDEO_BOT_TOKEN")
    if not TOKEN:
        print("ERROR: XVIDEO_BOT_TOKEN env var not set.", file=sys.stderr)
        return 1
    return run_polling_loop(TOKEN)


if __name__ == "__main__":
    sys.exit(main())
