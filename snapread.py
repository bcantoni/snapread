#!/Users/brian/.pyenv/versions/ai-3.14/bin/python
"""
snapread — scan recent iPhone screenshots from Photos library,
extract text via OCR and AI vision, and classify what each screenshot is of.
"""
import argparse
import base64
import json
import re
import shutil
import sqlite3
import tempfile
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

from ocrmac import ocrmac

PHOTOS_LIBRARY = Path.home() / "Pictures/Photos Library.photoslibrary"
PHOTOS_DB = PHOTOS_LIBRARY / "database/Photos.sqlite"
DERIVATIVES_DIR = PHOTOS_LIBRARY / "resources/derivatives"
THUMBNAILS_DIR = PHOTOS_LIBRARY / "resources/derivatives/masters"
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = "minicpm-v"
OLLAMA_PROMPT = (
    "This is an iPhone screenshot. In one sentence, describe what content is shown — "
    "focus on the subject matter (article title, social media post, product, etc.), "
    "not the phone UI chrome like the status bar or navigation."
)

# Core Data epoch: timestamps in Photos.sqlite are seconds since 2001-01-01
CORE_DATA_EPOCH = datetime(2001, 1, 1)

URL_RE = re.compile(r"https?://[^\s<>\"']+")

CLASSIFIERS = [
    ("app_store", re.compile(
        r"\bApp Store\b|\bGet\b.*\b(Free|Ratings?)\b|ratings and reviews",
        re.IGNORECASE
    )),
    ("code_docs", re.compile(
        r"github\.com|stackoverflow\.com|def |function |class |import |```",
        re.IGNORECASE
    )),
    ("map_location", re.compile(
        r"maps\.apple\.com|maps\.google\.com|\bDirections\b|\bETA\b|\bmi away\b|miles away",
        re.IGNORECASE
    )),
    ("recipe", re.compile(
        r"\btsp\b|\btbsp\b|\bcups?\b|\bservings?\b|\bingredients?\b|\bprep time\b|\bcook time\b",
        re.IGNORECASE
    )),
    ("shopping", re.compile(
        r"\$\d+[\.,]\d{2}|\bAdd to (Cart|Bag)\b|\bBuy Now\b|\bCheckout\b|\bamazon\.com\b",
        re.IGNORECASE
    )),
    ("chat_message", re.compile(
        r"\biMessage\b|\bSlack\b|\bTeams\b|\bWhatsApp\b|\bTelegram\b|\bDelivered\b|\bRead\b",
        re.IGNORECASE
    )),
    ("social_media", re.compile(
        r"\btwitter\.com\b|\bx\.com\b|\binstagram\.com\b|\breddit\.com\b|\btiktok\.com\b"
        r"|\bLikes?\b|\bRetweets?\b|\bReposts?\b|\bFollowers?\b",
        re.IGNORECASE
    )),
    ("article", re.compile(
        r"\bRead\b|\bShare\b|\bSave\b|\bmin read\b|\bSubscribe\b|\bSign (in|up)\b",
        re.IGNORECASE
    )),
]


def core_data_to_datetime(ts: float) -> datetime:
    return CORE_DATA_EPOCH + timedelta(seconds=ts)


def datetime_to_core_data(dt: datetime) -> float:
    return (dt - CORE_DATA_EPOCH).total_seconds()


def derivative_path(directory: str, filename: str) -> Path:
    base = Path(filename).stem
    return DERIVATIVES_DIR / directory / f"{base}_1_102_o.jpeg"


def thumbnail_path(directory: str, filename: str) -> Path:
    base = Path(filename).stem
    return THUMBNAILS_DIR / directory / f"{base}_4_5005_c.jpeg"


def ocr_image(path: Path) -> str:
    try:
        annotations = ocrmac.OCR(str(path)).recognize()
        return " ".join(text for text, _conf, _bbox in annotations)
    except Exception:
        return ""


def describe_image(path: Path) -> str:
    try:
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        payload = json.dumps({
            "model": OLLAMA_MODEL,
            "prompt": OLLAMA_PROMPT,
            "images": [b64],
            "stream": False,
        }).encode()
        req = urllib.request.Request(
            OLLAMA_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read()).get("response", "").strip()
    except Exception:
        return ""


def extract_urls(text: str) -> list[str]:
    seen = set()
    urls = []
    for url in URL_RE.findall(text):
        url = url.rstrip(".,;)")
        if url not in seen:
            seen.add(url)
            urls.append(url)
    return urls


def classify(text: str, urls: list[str]) -> str:
    combined = text + " " + " ".join(urls)
    for label, pattern in CLASSIFIERS:
        if pattern.search(combined):
            return label
    return "unknown"


def fetch_screenshots(days: int) -> list[tuple]:
    cutoff = datetime_to_core_data(datetime.now() - timedelta(days=days))
    with tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False) as tmp:
        tmp_path = tmp.name
    shutil.copy(PHOTOS_DB, tmp_path)

    conn = sqlite3.connect(tmp_path)
    rows = conn.execute(
        "SELECT ZDATECREATED, ZDIRECTORY, ZFILENAME FROM ZASSET "
        "WHERE ZKINDSUBTYPE = 10 AND ZDATECREATED > ? "
        "ORDER BY ZDATECREATED DESC",
        (cutoff,)
    ).fetchall()
    conn.close()
    Path(tmp_path).unlink(missing_ok=True)
    return rows


def download_missing(uuids: list[str], tmpdir: Path) -> dict[str, Path]:
    """Export iCloud-only screenshots via osxphotos. Returns uuid → exported path."""
    import osxphotos

    db = osxphotos.PhotosDB()
    photos = db.photos(uuid=uuids)
    exported: dict[str, Path] = {}

    for photo in photos:
        try:
            result = photo.export(str(tmpdir), use_photos_export=True, timeout=60)
            if result:
                exported[photo.uuid] = Path(result[0])
        except Exception:
            pass

    return exported


TYPE_COLORS = {
    "article":      "#2563eb",
    "social_media": "#7c3aed",
    "shopping":     "#d97706",
    "code_docs":    "#059669",
    "chat_message": "#6b7280",
    "recipe":       "#dc2626",
    "map_location": "#0891b2",
    "app_store":    "#4f46e5",
    "unknown":      "#9ca3af",
}


def generate_html(results: list[dict], days: int, all_urls: list[str],
                  skipped: int, html_path: Path) -> None:
    generated = datetime.now().strftime("%Y-%m-%d %H:%M")

    def card(r: dict) -> str:
        thumb = Path(r.get("thumbnail_path", ""))
        img_tag = f'<img src="file://{thumb}" alt="screenshot">' if thumb.exists() else '<div class="no-thumb">no thumbnail</div>'
        color = TYPE_COLORS.get(r["content_type"], "#9ca3af")
        date = r["date"][:16].replace("T", " ")
        desc = r.get("ai_description") or r.get("ocr_preview", "")
        urls_html = "".join(
            f'<a href="{u}" target="_blank">{u}</a>' for u in r["urls"]
        )
        return f"""
    <div class="card">
      <a href="file://{r['derivative_path']}" target="_blank">{img_tag}</a>
      <div class="info">
        <div class="meta">
          <span class="date">{date}</span>
          <span class="badge" style="background:{color}">{r['content_type']}</span>
        </div>
        <p class="desc">{desc}</p>
        {f'<div class="urls">{urls_html}</div>' if urls_html else ""}
      </div>
    </div>"""

    cards_html = "\n".join(card(r) for r in results)
    skip_note = f'<p class="skip-note">{skipped} screenshot{"s" if skipped != 1 else ""} skipped — not cached locally</p>' if skipped else ""

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>snapread — {generated}</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #f3f4f6; color: #111827; padding: 2rem; }}
    header {{ margin-bottom: 2rem; }}
    header h1 {{ font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }}
    header p {{ color: #6b7280; font-size: 0.875rem; margin-top: 0.25rem; }}
    .skip-note {{ color: #9ca3af; font-size: 0.8rem; margin-top: 0.5rem; }}
    .grid {{ display: grid;
             grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
             gap: 1.25rem; }}
    .card {{ background: #fff; border-radius: 12px; overflow: hidden;
             box-shadow: 0 1px 3px rgba(0,0,0,.08), 0 1px 2px rgba(0,0,0,.06);
             display: flex; flex-direction: column; }}
    .card a img, .card a {{ display: block; }}
    .card img {{ width: 100%; height: 220px; object-fit: cover; object-position: top;
                 background: #e5e7eb; }}
    .no-thumb {{ width: 100%; height: 220px; background: #e5e7eb;
                 display: flex; align-items: center; justify-content: center;
                 color: #9ca3af; font-size: 0.8rem; }}
    .info {{ padding: 0.875rem; display: flex; flex-direction: column; gap: 0.5rem; flex: 1; }}
    .meta {{ display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }}
    .date {{ font-size: 0.75rem; color: #6b7280; }}
    .badge {{ font-size: 0.65rem; font-weight: 600; color: #fff; padding: 0.15rem 0.5rem;
              border-radius: 99px; letter-spacing: 0.03em; text-transform: uppercase; }}
    .desc {{ font-size: 0.82rem; color: #374151; line-height: 1.5; }}
    .urls {{ display: flex; flex-direction: column; gap: 0.25rem; margin-top: auto; padding-top: 0.5rem;
             border-top: 1px solid #f3f4f6; }}
    .urls a {{ font-size: 0.75rem; color: #2563eb; text-decoration: none;
               white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
    .urls a:hover {{ text-decoration: underline; }}
  </style>
</head>
<body>
  <header>
    <h1>snapread</h1>
    <p>Last {days} day{"s" if days != 1 else ""} &middot; {len(results)} screenshots &middot; generated {generated}</p>
    {skip_note}
  </header>
  <div class="grid">
{cards_html}
  </div>
</body>
</html>"""

    html_path.write_text(html)


def ollama_available() -> bool:
    try:
        urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2)
        return True
    except Exception:
        return False


def process(days: int, output_path: Path, html_path: Path, fetch: bool, fast: bool) -> None:
    rows = fetch_screenshots(days)
    total = len(rows)

    use_ai = not fast
    if use_ai and not ollama_available():
        print("Note: Ollama not running — falling back to OCR-only. Start with: ollama serve\n")
        use_ai = False

    print(f"snapread — last {days} day{'s' if days != 1 else ''} — {total} screenshots found")
    mode = "OCR only" if not use_ai else f"OCR + {OLLAMA_MODEL}"
    print(f"mode: {mode}\n")

    # Identify and optionally download missing derivatives
    missing_uuids = []
    if fetch:
        for _ts, directory, filename in rows:
            path = derivative_path(directory, filename)
            if not path.exists():
                missing_uuids.append(Path(filename).stem)

    fetched: dict[str, Path] = {}
    tmpdir: Path | None = None
    if missing_uuids:
        tmpdir = Path(tempfile.mkdtemp(prefix="snapread_"))
        print(f"Downloading {len(missing_uuids)} screenshot(s) from iCloud via Photos...")
        fetched = download_missing(missing_uuids, tmpdir)
        print(f"Downloaded {len(fetched)} of {len(missing_uuids)}.\n")

    results = []
    skipped = 0
    all_urls: list[str] = []

    for i, (ts, directory, filename) in enumerate(rows, 1):
        uuid = Path(filename).stem
        path = derivative_path(directory, filename)

        if not path.exists():
            if uuid in fetched:
                path = fetched[uuid]
            else:
                skipped += 1
                continue

        date = core_data_to_datetime(ts)
        text = ocr_image(path)
        urls = extract_urls(text)
        content_type = classify(text, urls)

        description = ""
        if use_ai:
            print(f"[{i}/{total}] {date.strftime('%Y-%m-%d %H:%M')} — describing...", end="\r", flush=True)
            description = describe_image(path)

        url_label = f"{len(urls)} URL{'s' if len(urls) != 1 else ''}" if urls else "no URLs"
        print(f"{date.strftime('%Y-%m-%d %H:%M')}  {content_type:<14}  {url_label}")
        if description:
            print(f"  {description}")
        elif text:
            preview = text[:120].replace("\n", " ")
            print(f"  {preview}")

        thumb = thumbnail_path(directory, filename)
        all_urls.extend(u for u in urls if u not in all_urls)
        results.append({
            "date": date.isoformat(),
            "uuid": uuid,
            "derivative_path": str(path),
            "thumbnail_path": str(thumb) if thumb.exists() else "",
            "content_type": content_type,
            "urls": urls,
            "ai_description": description,
            "ocr_text": text,
            "ocr_preview": text[:120],
        })

    if tmpdir:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print()
    if all_urls:
        print(f"{len(all_urls)} URL{'s' if len(all_urls) != 1 else ''} found:")
        for url in all_urls:
            print(f"  {url}")
    else:
        print("No URLs found in OCR text.")

    if skipped:
        hint = "" if fetch else " (use --fetch to download from iCloud)"
        print(f"\n({skipped} screenshot{'s' if skipped != 1 else ''} skipped — not cached locally{hint})")

    output = {
        "generated_at": datetime.now().isoformat(),
        "days": days,
        "screenshots": results,
        "all_urls": all_urls,
        "skipped_count": skipped,
    }
    output_path.write_text(json.dumps(output, indent=2))
    print(f"\nJSON saved to: {output_path}")

    generate_html(results, days, all_urls, skipped, html_path)
    print(f"HTML saved to: {html_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Scan recent iPhone screenshots and extract bookmarkable content"
    )
    parser.add_argument("--days", type=int, default=7,
                        help="How many days back to scan (default: 7)")
    parser.add_argument("--output", type=Path, default=Path("snapread_output.json"),
                        help="JSON output file path (default: snapread_output.json)")
    parser.add_argument("--html", type=Path, default=Path("snapread_output.html"),
                        help="HTML output file path (default: snapread_output.html)")
    parser.add_argument("--fetch", action="store_true",
                        help="Download iCloud-only screenshots via Photos app before scanning")
    parser.add_argument("--fast", action="store_true",
                        help="Skip AI descriptions, use OCR only")
    args = parser.parse_args()
    process(args.days, args.output, args.html, args.fetch, args.fast)


if __name__ == "__main__":
    main()
