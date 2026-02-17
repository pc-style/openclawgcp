---
name: imgur-upload
description: Upload images to Imgur (free, no account needed) and get a public URL. Use as fallback when R2 is not configured.
metadata:
  {
    "openclaw":
      {
        "emoji": "📸",
        "os": ["linux", "macos"],
        "requires": { "bins": ["python3"] }
      }
  }
---

# Imgur Upload — Free Image Hosting

Upload images to Imgur anonymously and get a public URL. No API key needed for anonymous uploads.

## When to use

- When you need to **quickly share an image** without R2 credentials
- As a **fallback** when Cloudflare R2 is not configured
- When you need a **temporary image host** (Imgur images may expire after inactivity)
- For images under **20MB**

## Prerequisites (Environment Variables)

| Variable | Required | Description |
|----------|----------|-------------|
| `IMGUR_CLIENT_ID` | Optional | Imgur API client ID. If not set, uses anonymous upload (rate limited) |

> **To get a Client ID**: Go to https://api.imgur.com/oauth2/addclient → register app → get Client ID.
> Without Client ID, uploads still work but are more heavily rate-limited.

## Quick Usage

### Upload a local image

```shell
python3 /app/skills/imgur-upload/scripts/upload.py /path/to/image.jpg
```

Output: `https://i.imgur.com/AbCdEfG.jpg`

### Upload from URL

```shell
python3 /app/skills/imgur-upload/scripts/upload.py "https://example.com/photo.png"
```

### Upload with title

```shell
python3 /app/skills/imgur-upload/scripts/upload.py /tmp/screenshot.png --title "My Screenshot"
```

## Important Notes

- Max file size: **20MB** per image
- Supported formats: JPEG, PNG, GIF, APNG, TIFF, BMP, WebP
- Anonymous uploads may be **deleted after 6 months of inactivity**
- Rate limit: ~50 uploads/hour without Client ID, ~1250/day with Client ID
- For **permanent hosting**, use the `r2-upload` skill instead
