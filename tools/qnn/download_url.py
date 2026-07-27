import argparse
import shutil
import urllib.error
import urllib.request
from pathlib import Path


def download(urls: list[str], target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    for url in urls:
        try:
            existing = target.stat().st_size if target.is_file() else 0
            request = urllib.request.Request(url, headers={"User-Agent": "Talk2U-QAIRT/1.0"})
            if existing:
                request.add_header("Range", f"bytes={existing}-")
            with urllib.request.urlopen(request, timeout=60) as response:
                append = existing > 0 and response.status == 206
                mode = "ab" if append else "wb"
                with target.open(mode) as output:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
            return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
    raise RuntimeError(f"all download sources failed: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("target", type=Path)
    parser.add_argument("urls", nargs="+")
    arguments = parser.parse_args()
    download(arguments.urls, arguments.target)


if __name__ == "__main__":
    main()
