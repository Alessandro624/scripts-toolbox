"""Regression tests using disposable files only."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import socket

import pymupdf  # type: ignore

import extract_exercises as extractor

ROOT = Path(__file__).resolve().parents[1]


class ExtractionTests(unittest.TestCase):
    def test_continuations_and_chapter_boundary(self):
        chapters = extractor.collect_exercise_pages(
            [
                "CHAPTER 1 First\nExercises\n1. First question",
                "A continuation with no numbered items",
                "CHAPTER 2 Second\n1. This is not an exercise section",
                "Exercises\n1. Second question",
                "References\n1. Bibliography",
            ]
        )
        self.assertEqual(chapters[1]["pages"], [0, 1])
        self.assertEqual(chapters[2]["pages"], [3])

    def test_mixed_reference_page(self):
        chapters = extractor.collect_exercise_pages(
            [
                "CHAPTER 1 First\nExercises\n1. Question",
                "2. Last question\nReferences\n1. A book",
            ]
        )
        self.assertEqual(chapters[1]["pages"], [0, 1])

    def test_pdf_output_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "book.pdf"
            output = Path(folder) / "output"

            with pymupdf.open() as document:
                for text in ["CHAPTER 1 First\nExercises\n1. Question", "Continuation", "References"]:
                    document.new_page().insert_text((72, 72), text)
                document.save(source)

            original = source.read_bytes()
            extractor.extract_exercises_from_pdf(source, output)
            target = output / "01-First.pdf"

            with pymupdf.open(target) as result:
                self.assertEqual(len(result), 2)
                self.assertIn("Continuation", result[1].get_text())

            saved = target.read_bytes()

            with self.assertRaises(FileExistsError):
                extractor.extract_exercises_from_pdf(source, output)

            self.assertEqual(target.read_bytes(), saved)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(list(output.glob(".exercises-*")), [])

    def test_no_sections_creates_no_output(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "empty.pdf"
            output = Path(folder) / "output"

            with pymupdf.open() as document:
                document.new_page()
                document.save(source)

            self.assertEqual(extractor.extract_exercises_from_pdf(source, output), {})
            self.assertFalse(output.exists())


@unittest.skipUnless(shutil.which("php"), "PHP is not installed")
class TimestampTests(unittest.TestCase):
    def run_php(self, *args):
        return subprocess.run(
            ["php", str(ROOT / "update_file_timestamp_for_ftp.php"), *map(str, args)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_update_preserves_content_and_access_time(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "sample.txt"
            target.write_text("unchanged", encoding="utf-8")

            os.utime(target, (1600000000, 1600000000))

            result = self.run_php(target, "2026-04-07 20:19:24", "UTC")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(int(target.stat().st_mtime), 1775593164)
            self.assertEqual(int(target.stat().st_atime), 1600000000)
            self.assertEqual(target.read_text(), "unchanged")

    def test_invalid_date_does_not_modify_file(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "sample.txt"
            target.write_text("unchanged", encoding="utf-8")

            before = target.stat().st_mtime_ns

            for date, zone in [("2026-02-30 12:00:00", "UTC"), ("bad", "UTC"), ("2026-04-07 12:00:00", "invalid")]:
                result = self.run_php(target, date, zone)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.stat().st_mtime_ns, before)

    def test_missing_file_is_not_created(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "missing.txt"

            self.assertNotEqual(self.run_php(target, "2026-04-07 12:00:00").returncode, 0)
            self.assertFalse(target.exists())


@unittest.skipUnless(shutil.which("php"), "PHP is not installed")
class TimestampHttpTests(unittest.TestCase):
    def test_authentication_validation_and_update(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "sample.txt"
            target.write_text("unchanged", encoding="utf-8")

            os.utime(target, (1600000000, 1600000000))

            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]

            token = "test-only-token-" + "a" * 32

            environment = dict(os.environ, TIMESTAMP_TOKEN=token, TIMESTAMP_DIRECTORY=folder)

            server = subprocess.Popen(
                ["php", "-S", f"127.0.0.1:{port}", "-t", str(ROOT)],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            url = f"http://127.0.0.1:{port}/update_file_timestamp_for_ftp.php"
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def request(data=None, authenticated=True):
                headers = {"Authorization": f"Bearer {token}"} if authenticated else {}
                body = urllib.parse.urlencode(data).encode() if data is not None else None
                req = urllib.request.Request(url, data=body, headers=headers)

                try:
                    with opener.open(req, timeout=2) as response:
                        return response.status
                except urllib.error.HTTPError as error:
                    return error.code

            try:
                for _ in range(50):
                    try:
                        status = request()
                        break
                    except urllib.error.URLError:
                        if server.poll() is not None:
                            self.fail("PHP test server exited before startup")
                        time.sleep(0.05)
                else:
                    self.fail("PHP test server did not start")

                self.assertEqual(status, 405)
                valid = {"file": "sample.txt", "date": "2026-04-07 20:19:24", "timezone": "UTC"}
                self.assertEqual(request(valid, authenticated=False), 401)

                for filename in ["../sample.txt", "..\\sample.txt", "sample.txt:stream", "sample.txt."]:
                    self.assertEqual(request(dict(valid, file=filename)), 400)

                self.assertEqual(request(dict(valid, date="2026-02-30 12:00:00")), 400)
                self.assertEqual(int(target.stat().st_mtime), 1600000000)
                self.assertEqual(request(valid), 200)
                self.assertEqual(int(target.stat().st_mtime), 1775593164)
            finally:
                server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
