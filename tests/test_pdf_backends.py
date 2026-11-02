"""Integration tests for real PDF tools, skipped when a backend is absent."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import pymupdf  # type: ignore

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("PDF_TEST_BASH") or (shutil.which("bash") if os.name != "nt" else None)


def create_pdf(path, text):
    with pymupdf.open() as document:
        document.new_page().insert_text((72, 72), text)
        document.save(path)


@unittest.skipUnless(BASH, "Set PDF_TEST_BASH on Windows to use Git Bash")
class PdfBackendTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("pdfunite"), "Poppler is not installed")
    def test_real_merge(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            create_pdf(base / "01-Chapter-10.pdf", "Ten")
            create_pdf(base / "01-Chapter-2.pdf", "Two")
            subprocess.run([BASH, (ROOT / "merge_pdfs.sh").as_posix(), base.as_posix()], check=True)
            with pymupdf.open(base / "merged" / "01-Chapter.pdf") as document:
                self.assertEqual(len(document), 2)
                self.assertIn("Two", document[0].get_text())
                self.assertIn("Ten", document[1].get_text())

    @unittest.skipUnless(shutil.which("gs"), "Ghostscript is not installed")
    def test_real_compression(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / "sample.pdf"
            create_pdf(source, "Preserved text")
            original = source.read_bytes()
            subprocess.run([BASH, (ROOT / "compress_pdf.sh").as_posix(), base.as_posix()], check=True)
            with pymupdf.open(base / "compressed" / "sample.pdf") as document:
                self.assertEqual(len(document), 1)
                self.assertIn("Preserved text", document[0].get_text())
            self.assertEqual(source.read_bytes(), original)
