#!/usr/bin/env python3
"""
R2 Upload — Upload files to Cloudflare R2 and get public URL.

Usage:
    python3 upload.py <file_path_or_url> [--key custom/path.jpg]

Environment variables:
    R2_ACCESS_KEY_ID     - Required
    R2_SECRET_ACCESS_KEY - Required
    R2_ACCOUNT_ID        - Optional (default: 851741409acd69e96d6c480584a3c107)
    R2_BUCKET_NAME       - Optional (default: openclaw-images)
    R2_PUBLIC_DOMAIN     - Optional (default: https://pub-406cc49bf2114c608757721fa88725fa.r2.dev)
"""

import os
import sys
import mimetypes
import tempfile
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.parse import urlparse

# ── Config (from env or defaults) ──
ACCESS_KEY = os.environ.get("R2_ACCESS_KEY_ID", "")
SECRET_KEY = os.environ.get("R2_SECRET_ACCESS_KEY", "")
ACCOUNT_ID = os.environ.get("R2_ACCOUNT_ID", "851741409acd69e96d6c480584a3c107")
BUCKET = os.environ.get("R2_BUCKET_NAME", "openclaw-images")
PUBLIC_DOMAIN = os.environ.get("R2_PUBLIC_DOMAIN", "https://pub-406cc49bf2114c608757721fa88725fa.r2.dev")
ENDPOINT = f"https://{ACCOUNT_ID}.r2.cloudflarestorage.com"


def ensure_boto3():
    """Install boto3 if not available."""
    try:
        import boto3
        return boto3
    except ImportError:
        print("[r2-upload] Installing boto3...")
        os.system(f"{sys.executable} -m pip install -q --break-system-packages boto3 2>/dev/null")
        import boto3
        return boto3


def download_url(url: str) -> str:
    """Download a URL to a temp file, return the path."""
    parsed = urlparse(url)
    ext = Path(parsed.path).suffix or ".jpg"
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=30) as resp:
        data = resp.read()
    tmp = tempfile.NamedTemporaryFile(suffix=ext, delete=False)
    tmp.write(data)
    tmp.close()
    return tmp.name


def upload(file_path: str, key: str = None) -> str:
    """Upload a local file to R2. Returns the public URL."""
    if not ACCESS_KEY or not SECRET_KEY:
        print("ERROR: Missing R2_ACCESS_KEY_ID or R2_SECRET_ACCESS_KEY environment variables.")
        print("Set them with: export R2_ACCESS_KEY_ID=xxx R2_SECRET_ACCESS_KEY=yyy")
        sys.exit(1)

    boto3 = ensure_boto3()

    s3 = boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        region_name="auto",
    )

    file_path = str(Path(file_path).resolve())
    if not os.path.isfile(file_path):
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    if not key:
        key = Path(file_path).name

    content_type, _ = mimetypes.guess_type(file_path)
    if not content_type:
        content_type = "application/octet-stream"

    file_size = os.path.getsize(file_path)
    print(f"Uploading {key} ({file_size:,} bytes, {content_type})...")

    with open(file_path, "rb") as f:
        s3.upload_fileobj(
            f,
            BUCKET,
            key,
            ExtraArgs={"ContentType": content_type},
        )

    public_url = f"{PUBLIC_DOMAIN.rstrip('/')}/{key}"
    print(f"✅ Upload success!")
    print(f"URL: {public_url}")
    return public_url


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Upload files to Cloudflare R2")
    parser.add_argument("source", help="Local file path or URL to upload")
    parser.add_argument("--key", help="Custom key (path in bucket)", default=None)
    args = parser.parse_args()

    source = args.source
    tmp_file = None

    try:
        if source.startswith("http://") or source.startswith("https://"):
            print(f"Downloading {source}...")
            tmp_file = download_url(source)
            source = tmp_file

        upload(source, key=args.key)
    finally:
        if tmp_file and os.path.exists(tmp_file):
            os.unlink(tmp_file)


if __name__ == "__main__":
    main()
