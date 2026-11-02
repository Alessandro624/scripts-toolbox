"""Extract whole exercise pages from English, chapter-based PDF textbooks."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


def find_chapter_info(text: str) -> tuple[int, str] | None:
    match = re.search(r"^\s*CHAPTER[^\S\n]+(\d+)[^\S\n]+([^\n]+)", text, re.I | re.M)
    return (int(match[1]), match[2].strip()) if match else None


def has_exercises_section(text: str) -> bool:
    return bool(re.search(r"^\s*Exercises\s*$", text, re.I | re.M))


def has_references_section(text: str) -> bool:
    return bool(re.search(r"^\s*References\s*$", text, re.I | re.M))


def collect_exercise_pages(texts: list[str]) -> dict[int, dict]:
    """Include continuation pages; stop at References or a different chapter."""
    chapters: dict[int, dict] = {}
    current: int | None = None
    title = ""
    active = False

    for page_number, text in enumerate(texts):
        chapter = find_chapter_info(text)
        if chapter:
            if chapter[0] != current:
                active = False
            current, title = chapter

        exercise = re.search(r"^\s*Exercises\s*$", text, re.I | re.M)
        reference = re.search(r"^\s*References\s*$", text, re.I | re.M)

        if exercise and (not reference or exercise.start() < reference.start()):
            active = current is not None

        if active and current is not None:
            # A references-only page does not belong to the exercises. A mixed
            # page is retained whole if a numbered exercise precedes References.
            prefix = text[: reference.start()] if reference else text

            if not reference or exercise or re.search(r"^\s*\d+\.\s+", prefix, re.M):
                data = chapters.setdefault(current, {"title": title, "pages": []})
                data["pages"].append(page_number)

        if reference:
            active = False
    return chapters


def safe_title(title: str) -> str:
    title = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", title)
    return re.sub(r"\s+", "_", title).strip(" ._")[:50] or "Exercises"


def extract_exercises_from_pdf(pdf_path: str | Path, output_dir: str | Path) -> dict:
    try:
        import pymupdf  # type: ignore
    except ImportError as exc:
        raise RuntimeError("Install dependencies first: python -m pip install -r requirements.txt") from exc

    source = Path(pdf_path).resolve(strict=True)
    destination = Path(output_dir)

    with pymupdf.open(source) as document:
        if not document.is_pdf or document.needs_pass:
            raise ValueError("Input must be an unencrypted PDF.")
        chapters = collect_exercise_pages([page.get_text() for page in document])

        if not chapters:
            print("No exercise sections found. Scanned PDFs require OCR first.")
            return chapters

        targets = {number: destination / f"{number:02d}-{safe_title(data['title'])}.pdf" for number, data in chapters.items()}

        for target in targets.values():
            if target.exists() or target.is_symlink():
                raise FileExistsError(f"Output already exists: {target}")

        destination.mkdir(parents=True, exist_ok=True)

        for number, data in chapters.items():
            fd, temporary = tempfile.mkstemp(prefix=".exercises-", suffix=".pdf", dir=destination)
            os.close(fd)

            try:
                with pymupdf.open() as result:
                    for page in data["pages"]:
                        result.insert_pdf(document, from_page=page, to_page=page)

                    result.save(temporary)

                # Atomic publication without overwriting an existing file.
                if os.name == "nt":
                    os.rename(temporary, targets[number])
                else:
                    os.link(temporary, targets[number])
            finally:
                Path(temporary).unlink(missing_ok=True)

            print(f"Saved: {targets[number]} (source pages: {[p + 1 for p in data['pages']]})")
        return chapters


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path, help="Input PDF with selectable English text")
    parser.add_argument("-o", "--output-dir", type=Path, default=Path("exercises_output"))
    args = parser.parse_args()

    try:
        extract_exercises_from_pdf(args.pdf, args.output_dir)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
