# snapread

Scan recent iPhone screenshots from your macOS Photos library, extract text via OCR, and surface bookmarkable content — URLs, article titles, social posts, and more.

If you screenshot things on your phone to read later, this turns that pile into an actionable list.

## How it works

- Queries the Photos library SQLite database for screenshots (`ZKINDSUBTYPE = 10`)
- Reads full-resolution JPEG derivatives cached locally by Photos (no iCloud download needed)
- Runs OCR using Apple's native Vision framework via [ocrmac](https://github.com/straussmaximilian/ocrmac) — no model downloads, no API calls
- Classifies each screenshot by content type and extracts any URLs found
- Outputs a terminal table and a JSON file

## Requirements

- macOS (uses Apple's Vision framework for OCR)
- Python 3.10+
- Photos library at `~/Pictures/Photos Library.photoslibrary`

## Setup

```bash
pip install -r requirements.txt
```

## Usage

```bash
python snapread.py
python snapread.py --days 14
python snapread.py --days 30 --output bookmarks.json
python snapread.py --fetch          # download iCloud-only screenshots before scanning
```

| Flag | Default | Description |
|------|---------|-------------|
| `--days` | `7` | How many days back to scan |
| `--output` | `snapread_output.json` | JSON output file path |
| `--fetch` | off | Download iCloud-only screenshots via Photos app before scanning |

Without `--fetch`, screenshots that haven't been cached locally are skipped. With `--fetch`, snapread uses [osxphotos](https://github.com/RhetTbull/osxphotos) to trigger iCloud downloads for any missing screenshots before OCR runs. The Photos app must be able to reach iCloud. Downloaded files are cleaned up automatically.

## Output

Terminal:
```
snapread — last 7 days — 17 screenshots found

Date                Type             URLs  Preview
────────────────────────────────────────────────────────────────────────
2026-06-28 22:02    social_media        0  Emma Stone delivers her great...
2026-06-27 19:34    article             0  Every Agentic Engineering Hack...
2026-06-27 04:20    code_docs           0  Alex Hillman • @alexhillman...

2 URLs found:
  https://example.com/article
  https://lnkd.in/abc123
```

JSON (`snapread_output.json`):
```json
{
  "generated_at": "2026-06-28T15:00:00",
  "days": 7,
  "screenshots": [
    {
      "date": "2026-06-28T22:02:00",
      "uuid": "E48F2E8E-...",
      "derivative_path": "/Users/.../E48F2E8E_1_102_o.jpeg",
      "content_type": "social_media",
      "urls": [],
      "ocr_text": "...",
      "ocr_preview": "..."
    }
  ],
  "all_urls": [],
  "skipped_count": 0
}
```

## Content types

| Type | Detected from |
|------|--------------|
| `social_media` | Twitter/X, Instagram, Reddit, TikTok mentions; like/repost counts |
| `article` | Newsletter-style text, "Subscribe", "min read" |
| `shopping` | Price patterns, "Add to Cart", Amazon |
| `code_docs` | GitHub/Stack Overflow URLs, code syntax |
| `recipe` | Ingredient/measurement words |
| `chat_message` | iMessage, Slack, WhatsApp indicators |
| `map_location` | Maps URLs, "Directions", distance text |
| `app_store` | "App Store", ratings, "Get" button text |
| `unknown` | Fallback |

## Notes

- Screenshots must be cached locally by Photos. If a screenshot is iCloud-only and hasn't been downloaded, it is skipped (counted in `skipped_count`).
- Most iOS screenshot UIs display bare URLs (e.g. `x.com/...`) without the `https://` prefix, so URL extraction captures only fully-qualified URLs visible in the image.
