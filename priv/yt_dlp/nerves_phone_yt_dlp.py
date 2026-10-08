"""The Python half of NervesPhone.YtDlp.

Every function returns plain dicts, lists and strings (no yt-dlp objects),
already trimmed to what the Elixir side uses, so decoding stays cheap.
Results are ("ok", value) or ("error", message) tuples.
"""

import threading
import time
import traceback

import yt_dlp
from yt_dlp.utils import DownloadCancelled, DownloadError

class _Silent:
    """Drops yt-dlp's messages. Errors come back as return values instead."""

    def debug(self, msg):
        pass

    info = warning = error = debug


_BASE_OPTS = {
    "logger": _Silent(),
    "quiet": True,
    "no_warnings": True,
    "noprogress": True,
    "noplaylist": True,
    # yt-dlp caches signature solutions under ~/.cache; skip that.
    "cachedir": False,
}

# The JavaScript runtime for YouTube's challenges, set by configure().
_js_runtimes = {}


def configure(qjs):
    """Points yt-dlp at QuickJS, or at nothing when there's none."""
    global _js_runtimes
    _js_runtimes = {"quickjs": {"path": qjs}} if qjs else {}


def _opts(opts):
    js = {"js_runtimes": _js_runtimes} if _js_runtimes else {}
    return {**_BASE_OPTS, **js, **opts}


# Cancellation flags for running downloads, by download id.
_cancels = {}

# Seconds between progress messages.
_PROGRESS_INTERVAL = 0.5


def _run(opts, fun):
    try:
        with yt_dlp.YoutubeDL(_opts(opts)) as ydl:
            return ("ok", fun(ydl))
    except DownloadError as error:
        return ("error", _message(error))


def _message(error):
    # yt-dlp prefixes its messages with "ERROR: " for the terminal.
    return str(error).removeprefix("ERROR: ")


def _thumbnail(info):
    if info.get("thumbnail"):
        return info["thumbnail"]
    thumbnails = info.get("thumbnails") or []
    return thumbnails[-1].get("url") if thumbnails else None


def _entry(info):
    return {
        "id": info.get("id"),
        "title": info.get("title"),
        "url": info.get("webpage_url") or info.get("url"),
        "duration": info.get("duration"),
        "channel": info.get("channel") or info.get("uploader"),
        "thumbnail": _thumbnail(info),
        "is_live": bool(info.get("is_live")) or info.get("live_status") == "is_live",
        # "is_upcoming", "is_live", "post_live", "was_live" or "not_live",
        # when yt-dlp knows.
        "live_status": info.get("live_status"),
    }


def _format(f):
    return {
        "format_id": f.get("format_id"),
        "ext": f.get("ext"),
        "protocol": f.get("protocol"),
        "acodec": f.get("acodec"),
        "vcodec": f.get("vcodec"),
        "abr": f.get("abr"),
        "height": f.get("height"),
        "filesize": f.get("filesize") or f.get("filesize_approx"),
    }


def search(query, limit):
    def fun(ydl):
        # Flat extraction lists the results without resolving each video.
        result = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)
        return [_entry(e) for e in result.get("entries") or []]

    return _run({"extract_flat": "in_playlist", "noplaylist": False}, fun)


def info(url):
    def fun(ydl):
        info = ydl.extract_info(url, download=False)
        return {
            **_entry(info),
            "description": info.get("description"),
            "upload_date": info.get("upload_date"),
            "formats": [_format(f) for f in info.get("formats") or []],
        }

    return _run({}, fun)


def start_download(id, url, dir, format, send):
    """Starts a download in a thread and returns right away.

    `send(event)` is called from the thread with ("progress", downloaded,
    total), then ("done", path) or ("error", message, traceback). The
    traceback is None for yt-dlp's own errors, such as an unavailable video.
    """
    cancel = threading.Event()
    _cancels[id] = cancel
    last = 0.0

    def hook(d):
        nonlocal last

        if cancel.is_set():
            raise DownloadCancelled()

        now = time.monotonic()
        if d["status"] == "downloading" and now - last >= _PROGRESS_INTERVAL:
            last = now
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            send(("progress", d.get("downloaded_bytes") or 0, total))

    opts = {
        "format": format,
        # Merged video and audio go in MP4, which the phone plays.
        "merge_output_format": "mp4",
        "paths": {"home": dir},
        "outtmpl": "%(title).150B [%(id)s].%(ext)s",
        "progress_hooks": [hook],
    }

    def run():
        try:
            with yt_dlp.YoutubeDL(_opts(opts)) as ydl:
                info = ydl.extract_info(url, download=True)
            send(("done", info["requested_downloads"][0]["filepath"]))
        except Exception as error:
            # yt-dlp may wrap the hook's DownloadCancelled in another error.
            if cancel.is_set() or isinstance(error, DownloadCancelled):
                send(("error", "cancelled", None))
            elif isinstance(error, DownloadError):
                send(("error", _message(error), None))
            else:
                send(("error", _message(error), traceback.format_exc()))
        finally:
            _cancels.pop(id, None)

    threading.Thread(target=run, daemon=True).start()


def cancel_download(id):
    cancel = _cancels.get(id)
    if cancel:
        cancel.set()
