#!/usr/bin/env python3
"""
Imgur Upload — Upload images to Imgur anonymously.

Usage:
    python3 upload.py <file_path_or_url> [--title "My Image"]

Environment variables:
    IMGUR_CLIENT_ID - Optional (uses anonymous upload if not set)
"""

import os
import sys
import json
import base64
import tempfile
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.parse import urlparse, urlencode

# ── Config ──
CLIENT_ID = os.environ.get("IMGUR_CLIENT_ID", "546c25a59c58ad7")

IMGUR_API = "https://api.imgur.com/3/image"


def download_url(url: str) -> str:
    """Download a URL to a temp file."""
    parsed = urlparse(url)
    ext = Path(parsed.path).suffix or ".jpg"
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=30) as resp:
        data = resp.read()
    tmp = tempfile.NamedTemporaryFile(suffix=ext, delete=False)
    tmp.write(data)
    tmp.close()
    return tmp.name


def upload(file_path: str, title: str = None) -> str:
    """Upload a local image to Imgur. Returns the public URL."""
    file_path = str(Path(file_path).resolve())
    if not os.path.isfile(file_path):
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    file_size = os.path.getsize(file_path)
    if file_size > 20 * 1024 * 1024:
        print(f"ERROR: File too large ({file_size:,} bytes). Imgur limit is 20MB.")
        sys.exit(1)

    with open(file_path, "rb") as f:
        image_data = base64.b64encode(f.read()).decode("utf-8")

    payload = {"image": image_data, "type": "base64"}
    if title:
        payload["title"] = title

    data = urlencode(payload).encode("utf-8")
    req = Request(
        IMGUR_API,
        data=data,
        headers={
            "Authorization": f"Client-ID {CLIENT_ID}",
        },
        method="POST",
    )

    print(f"Uploading {Path(file_path).name} ({file_size:,} bytes)...")

    try:
        with urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        error_msg = str(e)
        if hasattr(e, 'read'):
            error_msg = e.read().decode('utf-8', errors='replace')
        print(f"ERROR: Imgur upload failed: {error_msg}")
        sys.exit(1)

    if not result.get("success"):
        print(f"ERROR: Imgur returned: {json.dumps(result, indent=2)}")
        sys.exit(1)

    link = result["data"]["link"]
    delete_hash = result["data"].get("deletehash", "N/A")

    print(f"✅ Upload success!")
    print(f"URL: {link}")
    print(f"Delete hash: {delete_hash}")
    return link


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Upload images to Imgur")
    parser.add_argument("source", help="Local file path or URL")
    parser.add_argument("--title", help="Image title", default=None)
    args = parser.parse_args()

    source = args.source
    tmp_file = None

    try:
        if source.startswith("http://") or source.startswith("https://"):
            print(f"Downloading {source}...")
            tmp_file = download_url(source)
            source = tmp_file

        upload(source, title=args.title)
    finally:
        if tmp_file and os.path.exists(tmp_file):
            os.unlink(tmp_file)


if __name__ == "__main__":
    main()
