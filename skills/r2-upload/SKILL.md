---
name: r2-upload
description: Upload files (images, documents) to Cloudflare R2 and get a public URL. Use when you need to host/share an image or file publicly.
metadata:
  {
    "openclaw":
      {
        "emoji": "☁️",
        "os": ["linux", "macos"],
        "requires": { "bins": ["python3"] },
        "env": ["R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
      }
  }
---

# R2 Upload — Cloudflare R2 File Hosting

Upload images and files to Cloudflare R2 storage and get a permanent public URL.

## When to use

- When you need to **host an image** and share the public URL
- When you generated an image and want to **send it in chat** (Telegram, Zalo, etc.)
- When you need to **store files permanently** in the cloud
- When someone asks you to upload or share an image/file

## Prerequisites (Environment Variables)

These MUST be set in the container environment:

| Variable | Description |
|----------|-------------|
| `R2_ACCESS_KEY_ID` | Cloudflare R2 API token (access key) |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 API secret key |
| `R2_ACCOUNT_ID` | Cloudflare account ID (default: `851741409acd69e96d6c480584a3c107`) |
| `R2_BUCKET_NAME` | R2 bucket name (default: `openclaw-images`) |
| `R2_PUBLIC_DOMAIN` | Public R2.dev domain (default: `https://pub-406cc49bf2114c608757721fa88725fa.r2.dev`) |

## Quick Usage

### Upload a file

```shell
python3 /app/skills/r2-upload/scripts/upload.py /path/to/image.jpg
```

Output: `https://pub-406cc49bf2114c608757721fa88725fa.r2.dev/image.jpg`

### Upload with custom key (path in bucket)

```shell
python3 /app/skills/r2-upload/scripts/upload.py /path/to/photo.png --key "agents/my-photo.png"
```

Output: `https://pub-406cc49bf2114c608757721fa88725fa.r2.dev/agents/my-photo.png`

### Upload from URL (download then upload)

```shell
python3 /app/skills/r2-upload/scripts/upload.py "https://example.com/image.jpg"
```

### Example: Generate image then upload

```shell
# 1. Generate or create image
python3 -c "
# ... generate image to /tmp/output.png
"

# 2. Upload to R2
python3 /app/skills/r2-upload/scripts/upload.py /tmp/output.png
```

## Important Notes

- Max file size: 300MB (R2 free tier limit for single upload)
- Supported: any file type (images, PDFs, videos, etc.)
- Files are **publicly accessible** once uploaded
- Duplicate filenames will be **overwritten** — use `--key` for custom paths
- If R2 credentials are missing, the script will error with a clear message
