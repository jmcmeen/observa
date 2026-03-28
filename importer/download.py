#!/usr/bin/env python3
"""Download iNaturalist Open Data files from S3 with progress bars and ETag caching."""

import os
import sys
import json
import threading
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore import UNSIGNED
from botocore.config import Config
from tqdm import tqdm

BUCKET = "inaturalist-open-data"
FILES = [
    "observations.csv.gz",
    "observers.csv.gz",
    "photos.csv.gz",
    "taxa.csv.gz",
]

CACHE_DIR = Path(os.environ.get("CACHE_DIR", "/data/cache"))
CHANGED_FLAG = CACHE_DIR / ".files_changed"

# Lock for thread-safe tqdm output
print_lock = threading.Lock()

s3 = boto3.client("s3", config=Config(signature_version=UNSIGNED))


def log(msg: str) -> None:
    with print_lock:
        print(f"[download] {msg}", flush=True)


def download_file(key: str) -> bool:
    """Download a single file. Returns True if downloaded, False if cached."""
    etag_file = CACHE_DIR / f"{key}.etag"
    cached_file = CACHE_DIR / key

    # Single head_object call for both ETag and ContentLength
    try:
        head = s3.head_object(Bucket=BUCKET, Key=key)
        remote_etag = head["ETag"]
        total_size = head["ContentLength"]
    except Exception:
        remote_etag = ""
        total_size = 0

    # Check cache
    if cached_file.exists() and etag_file.exists():
        local_etag = etag_file.read_text().strip()
        if remote_etag and remote_etag == local_etag:
            log(f"  {key}: unchanged (cached)")
            return False

    log(f"  {key}: downloading ({total_size / (1024**3):.1f} GB)...")

    # Download with progress bar
    with tqdm(
        total=total_size,
        unit="B",
        unit_scale=True,
        desc=key,
        leave=True,
        position=FILES.index(key),
    ) as pbar:
        s3.download_file(
            BUCKET,
            key,
            str(cached_file),
            Callback=lambda bytes_transferred: pbar.update(bytes_transferred),
        )

    # Save ETag
    if remote_etag:
        etag_file.write_text(remote_etag)

    # Signal that files changed
    CHANGED_FLAG.touch()
    log(f"  {key}: done")
    return True


def main() -> int:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    CHANGED_FLAG.unlink(missing_ok=True)

    log("Checking for updated data files on S3...")

    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(download_file, f): f for f in FILES}
        for future in as_completed(futures):
            key = futures[future]
            try:
                future.result()
            except Exception as e:
                log(f"  ERROR downloading {key}: {e}")
                return 1

    # Print blank lines to clear tqdm positions
    print()

    if CHANGED_FLAG.exists():
        log("New data downloaded.")
        return 0
    else:
        log("All files unchanged.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
