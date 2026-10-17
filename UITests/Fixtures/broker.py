#!/usr/bin/env python3
"""Local HTTPS broker data for simulator UI tests; never contacts Boosty."""
import argparse
import base64
import copy
import json
import math
from pathlib import Path
import re
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

ORIGIN = "https://localhost:18765"
PAIR_ID = "fixturepair0000000000000"
POLL_KEY = "p" * 43
COOKIE = "c" * 43
TV_PROOF = "t" * 43
APPLE_SAMPLE_MEDIA = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
PROFILE = {"id": "fixture-viewer", "name": "Fixture Viewer", "avatar": ORIGIN + "/media/image.png"}
AUTHORS = [
    {"blog": "flight-academy", "title": "Flight Academy", "name": "Flight Academy", "avatar": PROFILE["avatar"]},
    {"blog": "deep-space-lab", "title": "Deep Space Lab", "name": "Deep Space Lab", "avatar": PROFILE["avatar"]},
]


def posts(apple_sample_media=False):
    def post(identifier, title, blog="flight-academy", **changes):
        result = {
            "id": identifier, "title": title, "blog": blog,
            "author": next(author["name"] for author in AUTHORS if author["blog"] == blog),
            "summary": "A practical mission note for the remote reading and playback test.",
            "avatar": PROFILE["avatar"], "preview": ORIGIN + "/media/image.png",
            "createdAt": 1792195200, "publishedAt": 1792195200,
            "locked": False, "body": [], "videos": [],
        }
        result.update(changes)
        return result

    video = {
        "id": "orbital-video", "contentId": "orbital-video", "title": "Orbital mechanics",
        "preview": ORIGIN + "/media/image.png", "duration": 120, "timeCode": 40,
        "sources": [
            {"quality": "full_hd", "label": "1080p", "url": ORIGIN + "/media/test.mp4?quality=full_hd"},
            {"quality": "high", "label": "720p", "url": ORIGIN + "/media/test.mp4?quality=high"},
        ],
    }
    if apple_sample_media:
        for source in video["sources"]:
            source["url"] = APPLE_SAMPLE_MEDIA
    chapters = [
        {"type": "timecode", "title": title, "seconds": seconds,
         "videoId": video["id"], "description": description}
        for title, seconds, description in [
            ("Launch sequence", 0, "Prepare the spacecraft and begin the launch."),
            ("Orbit insertion", 30, "Establish a stable orbit and check the trajectory."),
            ("Return home", 60, "Plan the descent and complete the landing."),
        ]
    ]
    paragraph = ("Read the mission notes using the Siri Remote. Each orbital correction changes both the "
                 "speed and the path of the spacecraft. Check the fuel reserve before committing to a burn. "
                 "The flight director records the result and prepares the next maneuver. ")
    result = [
        post("p-video", "Orbital mechanics", videos=[video], body=chapters),
        post("p-reader", "Remote reading", body=[
            {"type": "link", "url": ORIGIN + "/handbook", "title": "Mission handbook"},
            {"type": "file", "url": ORIGIN + "/flight-checklist.pdf", "title": "Flight checklist.pdf"},
            {"type": "text", "text": "Mission reading notes\n\n" + "\n\n".join(
                f"Telemetry checkpoint {number:02d}. " + paragraph for number in range(1, 13))},
            {"type": "image", "url": ORIGIN + "/media/image.png", "title": "Orbital diagram"},
            {"type": "text", "text": "End of mission reading notes."},
        ]),
        post("p-image-failure", "Image recovery", body=[
            {"type": "image", "url": ORIGIN + "/media/retry.png", "title": "Recovered orbital diagram"}]),
        post("p-locked", "Members briefing", locked=True,
             body=[{"type": "text", "text": "Subscribe to Flight Academy to read this briefing."}]),
        post("p-empty", "Quiet orbit", preview=None),
        post("p-shared", "Academy shared mission"),
        post("p-shared", "Laboratory shared mission", blog="deep-space-lab"),
    ]
    for number in range(8, 25):
        result.append(post(f"p-note-{number:02d}", f"Mission log {number:02d}",
                           blog="deep-space-lab" if number % 2 == 0 else "flight-academy",
                           body=[{"type": "text", "text": f"Mission {number:02d}: telemetry reviewed and flight plan confirmed."}]))
    for index, item in enumerate(result):
        item["createdAt"] -= index * 86400
        item["publishedAt"] -= index * 86400
    return result


class Broker(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory, apple_sample_media=False):
        super().__init__(("127.0.0.1", 18765), Handler)
        self.directory = directory
        self.posts = posts(apple_sample_media)
        self.progress = {"orbital-video": 40}
        self.session_active = False
        self.image_attempts = 0
        self.lock = threading.Lock()
        self.png = "data:image/png;base64," + base64.b64encode((directory / "qr.png").read_bytes()).decode()
        self.jpeg = "data:image/jpeg;base64," + base64.b64encode((directory / "preview.jpg").read_bytes()).decode()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(directory / "cert.pem", directory / "key.pem")
        self.socket = context.wrap_socket(self.socket, server_side=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_data(self, status, data, content_type="application/json", headers=None):
        if not isinstance(data, bytes):
            data = json.dumps(data, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self.route()

    def do_HEAD(self):
        self.route()

    def do_POST(self):
        self.route()

    def route(self):
        target = urlsplit(self.path)
        path = unquote(target.path)
        query = parse_qs(target.query)
        body = {}
        if self.command == "POST":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 16384:
                    raise ValueError("body length")
                body = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError("JSON object required")
            except (ValueError, json.JSONDecodeError):
                self.send_data(400, {"code": "invalid_json"})
                return
        if path == "/health":
            self.send_data(200, {"status": "ok", "fixture": "boosty-appletv"})
            return
        if path.startswith("/media/"):
            self.media(path)
            return
        if path == "/api/pairs" and self.command == "POST":
            self.send_data(201, {"id": PAIR_ID, "pollKey": POLL_KEY,
                                "linkUrl": ORIGIN + "/link/" + PAIR_ID + "#" + "l" * 43,
                                "qrImage": self.server.png, "expiresAt": self.expires_at()})
            return
        if path == "/api/pairs/" + PAIR_ID:
            if self.headers.get("X-Poll-Key") != POLL_KEY:
                self.send_data(403, {"code": "pair_key"})
                return
            self.send_data(200, {"state": "confirm", "name": "Apple TV", "profile": PROFILE,
                                 "expiresAt": self.expires_at()})
            return
        if path == "/api/pairs/" + PAIR_ID + "/finish" and self.command == "POST":
            if self.headers.get("X-Poll-Key") != POLL_KEY:
                self.send_data(403, {"code": "pair_key"})
                return
            self.server.session_active = True
            self.send_data(200, {"profile": PROFILE, "tvProof": TV_PROOF}, headers={
                "Set-Cookie": f"boostytv={COOKIE}; Path=/; HttpOnly; Secure; SameSite=None; Max-Age=86400"})
            return
        if (not self.server.session_active or self.headers.get("X-TV-Proof") != TV_PROOF
                or f"boostytv={COOKIE}" not in self.headers.get("Cookie", "").split("; ")):
            self.send_data(401, {"code": "reconnect"})
            return
        if path == "/api/me":
            self.send_data(200, PROFILE)
        elif path == "/api/subscriptions":
            self.send_data(200, {"items": AUTHORS, "nextOffset": None})
        elif path == "/api/feed" or path.startswith("/api/blog/"):
            try:
                offset = int(query.get("offset", ["0"])[0])
                if offset < 0:
                    raise ValueError("offset")
            except ValueError:
                self.send_data(400, {"code": "offset"})
                return
            items = self.server.posts
            if path.startswith("/api/blog/"):
                items = [item for item in items if item["blog"] == path.rsplit("/", 1)[1]]
            page = copy.deepcopy(items[offset:offset + 10])
            for post in page:
                for video in post["videos"]:
                    video["timeCode"] = self.server.progress.get(video["id"], 0)
            next_offset = str(offset + 10) if offset + 10 < len(items) else None
            self.send_data(200, {"items": page, "nextOffset": next_offset})
        elif path.startswith("/api/post/"):
            parts = path.split("/")
            post = next((item for item in self.server.posts
                         if len(parts) == 5 and (item["blog"], item["id"]) == (parts[3], parts[4])), None)
            if post:
                result = copy.deepcopy(post)
                for video in result["videos"]:
                    video["timeCode"] = self.server.progress.get(video["id"], 0)
                self.send_data(200, result)
            else:
                self.send_data(404, {"code": "post_missing"})
        elif path.startswith("/api/progress/"):
            self.send_data(200, {"seconds": self.server.progress.get(path.rsplit("/", 1)[1], 0)})
        elif path == "/api/progress" and self.command == "POST":
            seconds = body.get("seconds")
            if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or not 0 <= seconds <= 604800:
                self.send_data(400, {"code": "progress_seconds"})
                return
            self.server.progress[body.get("videoId", "")] = math.floor(seconds)
            self.send_data(200, {"ok": True})
        elif path.startswith("/api/preview/"):
            try:
                seconds = float(query["seconds"][0])
                if not math.isfinite(seconds) or seconds < 0:
                    raise ValueError("seconds")
            except (KeyError, ValueError):
                self.send_data(400, {"code": "preview_seconds"})
                return
            self.send_data(200, {"image": self.server.jpeg, "seconds": seconds})
        elif path == "/api/qr" and self.command == "POST":
            self.send_data(200, {"qrImage": self.server.png})
        elif path == "/api/logout" and self.command == "POST":
            self.server.session_active = False
            self.send_data(200, {"ok": True}, headers={"Set-Cookie": "boostytv=; Path=/; Max-Age=0; Secure; HttpOnly"})
        else:
            self.send_data(404, {"code": "not_found"})

    @staticmethod
    def expires_at():
        return int(time.time() * 1000) + 300000

    def media(self, path):
        if path == "/media/retry.png":
            with self.server.lock:
                self.server.image_attempts += 1
                first = self.server.image_attempts == 1
            if first:
                self.send_data(503, {"code": "upstream"})
                return
            path = "/media/image.png"
        name = path.removeprefix("/media/")
        if name not in {"image.png", "preview.jpg", "qr.png", "test.mp4"}:
            self.send_data(404, {"code": "not_found"})
            return
        file = self.server.directory / name
        size = file.stat().st_size
        start, end, status = 0, size - 1, 200
        headers = {"Accept-Ranges": "bytes"}
        byte_range = self.headers.get("Range")
        if byte_range:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", byte_range)
            if match and (match[1] or match[2]):
                if not match[1]:
                    start = max(0, size - int(match[2]))
                else:
                    start = int(match[1])
                    end = min(size - 1, int(match[2])) if match[2] else size - 1
            else:
                start = size
            if start >= size or end < start:
                self.send_data(416, b"", headers={"Content-Range": f"bytes */{size}"})
                return
            status = 206
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        self.send_response(status)
        self.send_header("Content-Type", {".mp4": "video/mp4", ".png": "image/png", ".jpg": "image/jpeg"}[file.suffix])
        self.send_header("Content-Length", str(end - start + 1))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            with file.open("rb") as stream:
                stream.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = stream.read(min(65536, remaining))
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # AVPlayer cancels obsolete range requests when seeking.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--apple-sample-media", action="store_true",
                        help="Use public Apple HLS content for the separate fixture app host.")
    arguments = parser.parse_args()
    server = Broker(arguments.directory.resolve(), arguments.apple_sample_media)
    print(f"Fixture broker listening on {ORIGIN}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
