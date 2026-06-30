#!/Users/brian/.pyenv/versions/ai-3.14/bin/python
"""
snapread — scan recent iPhone screenshots from Photos library,
extract text via OCR, and classify what each screenshot is of.
"""
import argparse
import json
import re
import shutil
import sqlite3
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

from ocrmac import ocrmac

PHOTOS_LIBRARY = Path.home() / "Pictures/Photos Library.photoslibrary"
PHOTOS_DB = PHOTOS_LIBRARY / "database/Photos.sqlite"
DERIVATIVES_DIR = PHOTOS_LIBRARY / "resources/derivatives"

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


def ocr_image(path: Path) -> str:
    try:
        annotations = ocrmac.OCR(str(path)).recognize()
        return " ".join(text for text, _conf, _bbox in annotations)
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


def process(days: int, output_path: Path, fetch: bool) -> None:
    rows = fetch_screenshots(days)
    total = len(rows)

    print(f"\nsnapread — last {days} day{'s' if days != 1 else ''} — {total} screenshots found\n")

    # Identify which rows have missing derivatives
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

    col_w = (18, 14, 5, 45)
    header = f"{'Date':<{col_w[0]}}  {'Type':<{col_w[1]}}  {'URLs':>{col_w[2]}}  {'Preview':<{col_w[3]}}"
    print(header)
    print("─" * (sum(col_w) + 6))

    results = []
    skipped = 0
    all_urls: list[str] = []

    for ts, directory, filename in rows:
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
        preview = text[:col_w[3]].replace("\n", " ") if text else "(no text)"

        date_str = date.strftime("%Y-%m-%d %H:%M")
        print(f"{date_str:<{col_w[0]}}  {content_type:<{col_w[1]}}  {len(urls):>{col_w[2]}}  {preview:<{col_w[3]}}")

        all_urls.extend(u for u in urls if u not in all_urls)
        results.append({
            "date": date.isoformat(),
            "uuid": uuid,
            "derivative_path": str(path),
            "content_type": content_type,
            "urls": urls,
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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Scan recent iPhone screenshots and extract bookmarkable content"
    )
    parser.add_argument("--days", type=int, default=7, help="How many days back to scan (default: 7)")
    parser.add_argument("--output", type=Path, default=Path("snapread_output.json"),
                        help="JSON output file path (default: snapread_output.json)")
    parser.add_argument("--fetch", action="store_true",
                        help="Download iCloud-only screenshots via Photos app before scanning")
    args = parser.parse_args()
    process(args.days, args.output, args.fetch)


if __name__ == "__main__":
    main()
