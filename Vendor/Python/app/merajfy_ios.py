"""Merajfy on the iPhone: the part that needs yt-dlp. Runs inside the app's own Python (no other process).

  warmup()                                        import yt-dlp
  search(query)                                   "ytsearch5:..." -> JSON list of {id, title, duration}
  download(video_id, outdir, cancel_path, progress_path)
                                                  downloads the AAC (m4a) audio into outdir -> JSON {"file": path}
Every function returns a JSON string: {"error": "..."} when something went wrong. No FFmpeg, no JavaScript runtime.
"""
import json
import os
import time

# yt-dlp tries to start programs (ffmpeg, deno, ...) to look for them. iOS cannot start programs: refuse cleanly.
import subprocess  # noqa: E402


def _refuse(*args, **kwargs):
    raise OSError("starting other programs is not possible on iOS")


subprocess.Popen.__init__ = _refuse
for _name in ("fork", "forkpty", "system", "posix_spawn", "posix_spawnp", "execv", "execve", "execvp"):
    if hasattr(os, _name):
        setattr(os, _name, _refuse)


class _Silent:
    def debug(self, msg): pass
    def info(self, msg): pass
    def warning(self, msg): pass
    def error(self, msg): self.last = msg


class _Cancelled(Exception):
    pass


def _prepare():
    import certifi
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
    import yt_dlp
    return yt_dlp


def warmup():
    yt_dlp = _prepare()
    return json.dumps({"yt_dlp": yt_dlp.version.__version__})


def search(query):
    try:
        yt_dlp = _prepare()
        opts = {"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True, "cachedir": False,
                "socket_timeout": 15, "retries": 3, "logger": _Silent()}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(query, download=False)
        out = []
        for e in (info or {}).get("entries") or []:
            if e and e.get("id"):
                out.append({"id": e["id"], "title": e.get("title"), "duration": e.get("duration")})
        return json.dumps(out)
    except Exception as e:  # noqa: BLE001 - reported to the app
        return json.dumps({"error": _friendly(str(e))})


def _friendly(raw):
    s = raw.lower()
    if "sign in to confirm" in s or "bot" in s or "429" in s:
        return "YouTube is refusing this network (bot check). Try another network."
    if "requested format is not available" in s:
        return "YouTube offered no m4a audio for this video."
    if "video unavailable" in s or "private video" in s or "not available" in s:
        return "The matched YouTube video is unavailable."
    if "name or service not known" in s or "urlopen error" in s or "timed out" in s or "network is unreachable" in s:
        return "No internet connection."
    return (raw or "download failed")[:200]


def download(video_id, outdir, cancel_path, progress_path):
    yt_dlp = _prepare()
    os.makedirs(outdir, exist_ok=True)
    last_write = [0.0]

    def hook(d):
        if os.path.exists(cancel_path):
            raise _Cancelled()
        now = time.time()
        if now - last_write[0] >= 0.4:
            last_write[0] = now
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            try:
                with open(progress_path, "w") as fh:
                    json.dump({"done": d.get("downloaded_bytes") or 0, "total": total}, fh)
            except OSError:
                pass

    attempts = [{}, {"extractor_args": {"youtube": {"player_client": ["tv", "web_safari", "android"]}}}]
    last_error = ""
    for extra in attempts:
        log = _Silent()
        log.last = ""
        opts = {
            "logger": log, "quiet": True, "no_warnings": True, "noplaylist": True, "cachedir": False,
            "socket_timeout": 20, "retries": 10, "noprogress": True, "continuedl": True, "overwrites": True,
            "format": "140/bestaudio[ext=m4a]",                 # AAC in an m4a container: plays natively, needs no FFmpeg
            "outtmpl": os.path.join(outdir, "raw-%(id)s.%(ext)s"),
            "postprocessors": [], "fixup": "never",
            "progress_hooks": [hook],
            **extra,
        }
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info("https://www.youtube.com/watch?v=" + video_id, download=True)
            path = None
            for r in (info.get("requested_downloads") or []):
                path = r.get("filepath") or path
            if not path or not os.path.exists(path):
                raise RuntimeError("the download finished but no file was written")
            return json.dumps({"file": path})
        except _Cancelled:
            return json.dumps({"cancelled": True})
        except Exception as e:  # noqa: BLE001
            if "_Cancelled" in repr(e) or os.path.exists(cancel_path):
                return json.dumps({"cancelled": True})
            last_error = last_error or log.last or str(e)       # the first attempt's reason is the useful one
    return json.dumps({"error": _friendly(last_error)})
