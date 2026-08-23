#!/usr/bin/env python3
"""parse-document 的 host unit test；不需要 Docker、curl 或 Docling。"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import contextlib
import io
import os
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from types import SimpleNamespace
from types import ModuleType
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "agents/bin/parse-document"


def load_cli():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_loader(
        "parse_document", importlib.machinery.SourceFileLoader("parse_document", str(CLI))
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def check(name: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"{name}: {detail}" if detail else name)


def expect_error(name: str, callback, text: str | None = None) -> str:
    try:
        callback()
    except cli_error_type as exc:  # type: ignore[name-defined]
        if text is not None:
            check(name, text in str(exc), str(exc))
        return str(exc)
    raise AssertionError(f"{name}: error was not raised")


def archive(path: Path, *infos: zipfile.ZipInfo) -> None:
    with zipfile.ZipFile(path, "w") as output:
        for info in infos:
            output.writestr(info, b"x")


def minimal_ooxml(cli, path: Path, extension: str) -> None:
    required_part, content_type, root_tag = cli.OOXML_REQUIRED_PARTS[extension]
    namespace, local_name = root_tag[1:].split("}", 1)
    content_types = f'''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="{cli.OOXML_CONTENT_TYPES_NAMESPACE}">
  <Override PartName="/{required_part}" ContentType="{content_type}"/>
</Types>'''.encode()
    with zipfile.ZipFile(path, "w") as output:
        output.writestr("[Content_Types].xml", content_types)
        output.writestr(
            required_part,
            f'<?xml version="1.0"?><{local_name} xmlns="{namespace}"/>'.encode(),
        )


def mocked_docling(cli, *, converter_options, markdown):
    """提供最小 Docling import mock，測試不需要安裝或下載模型。"""
    document_converter = ModuleType("docling.document_converter")
    base_models = ModuleType("docling.datamodel.base_models")
    pipeline_options = ModuleType("docling.datamodel.pipeline_options")
    docling = ModuleType("docling")
    datamodel = ModuleType("docling.datamodel")
    docling.__path__ = []
    datamodel.__path__ = []

    class FakeInputFormat:
        PDF = "pdf"

    class FakePdfPipelineOptions:
        instances = []

        def __init__(self, *, artifacts_path, do_ocr, do_table_structure):
            self.artifacts_path = artifacts_path
            self.do_ocr = do_ocr
            self.do_table_structure = do_table_structure
            self.__class__.instances.append(self)

    class FakePdfFormatOption:
        instances = []

        def __init__(self, *, pipeline_options):
            self.pipeline_options = pipeline_options
            self.__class__.instances.append(self)

    class FakeDocument:
        def export_to_markdown(self):
            return markdown

    class FakeResult:
        document = FakeDocument()

    class FakeDocumentConverter:
        instances = []

        def __init__(self, **kwargs):
            self.options = kwargs.get("format_options")
            self.__class__.instances.append(self)

        def convert(self, path, **kwargs):
            self.path = path
            self.convert_kwargs = kwargs
            return FakeResult()

    base_models.InputFormat = FakeInputFormat
    pipeline_options.PdfPipelineOptions = FakePdfPipelineOptions
    document_converter.DocumentConverter = FakeDocumentConverter
    document_converter.PdfFormatOption = FakePdfFormatOption
    return {
        "docling": docling,
        "docling.datamodel": datamodel,
        "docling.datamodel.base_models": base_models,
        "docling.datamodel.pipeline_options": pipeline_options,
        "docling.document_converter": document_converter,
    }, FakeDocumentConverter, FakePdfPipelineOptions, FakePdfFormatOption


def main() -> int:
    cli = load_cli()
    global cli_error_type
    cli_error_type = cli.ParseDocumentError
    source = CLI.read_text()
    check(
        "runtime parser has no Docling model downloader",
        "docling-tools" not in source and "docling_tools" not in source,
    )
    workdir = Path(tempfile.mkdtemp(prefix="parse-document-test-"))
    try:
        # URL validation uses the exact configured R2 path-style hostname.
        previous_host = os.environ.get(cli.PARSE_DOCUMENT_ALLOWED_HOST)
        os.environ[cli.PARSE_DOCUMENT_ALLOWED_HOST] = cli.R2_PATH_STYLE_HOST
        valid_url = f"https://{cli.R2_PATH_STYLE_HOST}/incoming/document.pdf?signature=secret"
        check("R2 path-style HTTPS URL is accepted", cli.validate_url(valid_url) is None)
        expect_error(
            "HTTP URL is rejected",
            lambda: cli.validate_url(valid_url.replace("https://", "http://", 1)),
            "HTTPS",
        )
        expect_error(
            "host mismatch is rejected",
            lambda: cli.validate_url("https://other.example/document.pdf"),
            "host is not allowed",
        )
        expect_error(
            "userinfo is rejected",
            lambda: cli.validate_url(f"https://user@{cli.R2_PATH_STYLE_HOST}/document.pdf"),
            "userinfo",
        )
        expect_error(
            "port is rejected",
            lambda: cli.validate_url(f"https://{cli.R2_PATH_STYLE_HOST}:443/document.pdf"),
            "port",
        )

        os.environ[cli.PARSE_DOCUMENT_ALLOWED_HOST] = "10.0.0.1"
        expect_error(
            "private IP is rejected",
            lambda: cli.validate_url("https://10.0.0.1/document.pdf"),
            "host is not allowed",
        )
        os.environ[cli.PARSE_DOCUMENT_ALLOWED_HOST] = "localhost"
        expect_error(
            "localhost is rejected",
            lambda: cli.validate_url("https://localhost/document.pdf"),
            "host is not allowed",
        )
        os.environ.pop(cli.PARSE_DOCUMENT_ALLOWED_HOST, None)
        expect_error(
            "missing allowed host is rejected",
            lambda: cli.validate_url(valid_url),
            "not configured",
        )
        os.environ[cli.PARSE_DOCUMENT_ALLOWED_HOST] = cli.R2_PATH_STYLE_HOST

        # The curl invocation must not enable redirects, and its failure text is URL-free.
        captured_command: list[str] = []

        class FakeProcess:
            stdout = io.BytesIO(b"download")

            def wait(self):
                return 0

            def kill(self):
                pass

        original_popen = cli.subprocess.Popen

        def fake_popen(command, **kwargs):
            captured_command.extend(command)
            check("curl stderr is suppressed", kwargs.get("stderr") is cli.subprocess.DEVNULL)
            return FakeProcess()

        cli.subprocess.Popen = fake_popen
        try:
            cli._download_with_curl(valid_url, str(workdir / "downloaded"))
        finally:
            cli.subprocess.Popen = original_popen
        check(
            "curl redirect arguments are absent",
            not {"--location", "-L", "--proto-redir"}.intersection(captured_command),
        )

        # PARSE_DOCUMENT_WORKDIR cannot redirect the controlled TemporaryDirectory.
        requested_workdir = workdir / "attacker-controlled"
        os.environ["PARSE_DOCUMENT_WORKDIR"] = str(requested_workdir)
        seen_workdir: list[str] = []
        original_process_document = cli._process_document
        cli._process_document = lambda url, extension, selected: seen_workdir.append(selected)
        try:
            check("main succeeds with injected workdir ignored", cli.main([valid_url, "document.pdf"]) == 0)
        finally:
            cli._process_document = original_process_document
            os.environ.pop("PARSE_DOCUMENT_WORKDIR", None)
        check("controlled workdir is under /tmp", seen_workdir and seen_workdir[0].startswith("/tmp/"))
        check("injected workdir was not used", seen_workdir[0] != str(requested_workdir))

        # ZIP path traversal is rejected before any member is read.
        traversal = workdir / "traversal.zip"
        archive(traversal, zipfile.ZipInfo("../outside.txt"))
        try:
            cli.list_zip_entries(str(traversal))
        except cli.ParseDocumentError as exc:
            check("ZIP traversal is rejected", "unsafe path" in str(exc))
        else:
            raise AssertionError("ZIP traversal was accepted")

        absolute = workdir / "absolute.zip"
        archive(absolute, zipfile.ZipInfo("/etc/passwd"))
        try:
            cli.list_zip_entries(str(absolute))
        except cli.ParseDocumentError as exc:
            check("ZIP absolute path is rejected", "unsafe path" in str(exc))
        else:
            raise AssertionError("ZIP absolute path was accepted")

        # Metadata-only checks cover per-entry size, total size, encryption bit and symlink mode.
        too_big = SimpleNamespace(
            filename="large.bin", flag_bits=0, external_attr=0, file_size=cli.MAX_ZIP_ENTRY_BYTES + 1
        )
        try:
            cli.validate_zip_infos([too_big])
        except cli.ParseDocumentError as exc:
            check("oversized ZIP entry is rejected", "10 MiB" in str(exc))
        else:
            raise AssertionError("oversized ZIP entry was accepted")

        total = [
            SimpleNamespace(filename=f"part-{index}", flag_bits=0, external_attr=0, file_size=cli.MAX_ZIP_ENTRY_BYTES)
            for index in range(11)
        ]
        try:
            cli.validate_zip_infos(total)
        except cli.ParseDocumentError as exc:
            check("oversized ZIP total is rejected", "100 MiB" in str(exc))
        else:
            raise AssertionError("oversized ZIP total was accepted")

        encrypted = SimpleNamespace(filename="secret.txt", flag_bits=0x1, external_attr=0, file_size=1)
        try:
            cli.validate_zip_infos([encrypted])
        except cli.ParseDocumentError as exc:
            check("encrypted ZIP metadata is rejected", "encrypted" in str(exc))
        else:
            raise AssertionError("encrypted ZIP metadata was accepted")

        symlink = SimpleNamespace(
            filename="link", flag_bits=0, external_attr=(stat.S_IFLNK | 0o777) << 16, file_size=4
        )
        try:
            cli.validate_zip_infos([symlink])
        except cli.ParseDocumentError as exc:
            check("ZIP symlink metadata is rejected", "symlink" in str(exc))
        else:
            raise AssertionError("ZIP symlink metadata was accepted")

        # ZIP listing output is budgeted while each line is built, not after a
        # potentially huge Markdown string has already been formed.
        long_names = workdir / "long-names.zip"
        with zipfile.ZipFile(long_names, "w") as output:
            for index in range(cli.MAX_ZIP_MEMBERS):
                output.writestr(f"{index:04d}-" + "n" * 11000, b"")
        expect_error(
            "ZIP listing output budget is enforced",
            lambda: cli.list_zip_entries(str(long_names)),
            "10 MiB",
        )

        # OOXML metadata is checked before Docling, so an XML ZIP bomb is rejected.
        ooxml_bomb = SimpleNamespace(
            filename="word/document.xml",
            flag_bits=0,
            external_attr=0,
            file_size=cli.MAX_ZIP_ENTRY_BYTES + 1,
        )

        class FakeOOXMLArchive:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def infolist(self):
                return [ooxml_bomb]

        original_zipfile = cli.zipfile.ZipFile
        cli.zipfile.ZipFile = lambda path: FakeOOXMLArchive()
        try:
            expect_error(
                "OOXML XML ZIP metadata is rejected",
                lambda: cli.validate_ooxml_archive(str(workdir / "document"), ".docx"),
                "10 MiB",
            )
        finally:
            cli.zipfile.ZipFile = original_zipfile

        valid_pdf = workdir / "document.pdf"
        valid_pdf.write_bytes(b"%PDF-1.7\nminimal test PDF")
        disguised_ooxml = workdir / "ooxml.pdf"
        minimal_ooxml(cli, disguised_ooxml, ".docx")
        expect_error(
            "OOXML disguised as PDF is rejected",
            lambda: cli._convert_with_docling(str(disguised_ooxml), ".pdf"),
            "does not match",
        )
        fake_pdf_office = workdir / "fake.docx"
        fake_pdf_office.write_bytes(b"%PDF-1.7\nnot an Office package")
        expect_error(
            "fake PDF disguised as Office is rejected",
            lambda: cli._convert_with_docling(str(fake_pdf_office), ".docx"),
            "does not match",
        )
        for extension in (".docx", ".xlsx", ".pptx"):
            downloaded = workdir / "document"
            minimal_ooxml(cli, downloaded, extension)
            check(
                f"minimal {extension} structure is accepted without a temp-file suffix",
                cli.validate_document_content(str(downloaded), extension) is None,
            )

        expect_error(
            "oversized Markdown output is rejected",
            lambda: cli._validate_markdown_output("x" * (cli.MAX_DOC_OUTPUT_BYTES + 1)),
            "10 MiB",
        )
        check("Docling page limit is 200", cli.MAX_DOC_PAGES == 200)
        check("Docling timeout is 120 seconds", cli.DOCLING_TIMEOUT_SECONDS == 120)

        # PDF conversion must use the configured, pre-fetched artifact directory;
        # a missing directory fails before importing Docling and cannot download.
        os.environ.pop(cli.DOCLING_ARTIFACTS_PATH, None)
        expect_error(
            "PDF conversion rejects a missing artifacts env",
            lambda: cli._convert_with_docling(str(workdir / "document.pdf"), ".pdf"),
            "not configured",
        )
        artifacts = workdir / "models"
        os.environ[cli.DOCLING_ARTIFACTS_PATH] = str(artifacts)
        expect_error(
            "PDF conversion rejects a missing artifacts directory",
            lambda: cli._convert_with_docling(str(workdir / "document.pdf"), ".pdf"),
            "unavailable",
        )
        artifacts.mkdir()
        valid_pdf = workdir / "document.pdf"
        modules, fake_converter, fake_options, fake_pdf_format = mocked_docling(
            cli, converter_options=True, markdown="# PDF\n"
        )
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(sys.modules, modules))
            stack.enter_context(
                mock.patch.object(
                    cli.subprocess,
                    "Popen",
                    side_effect=AssertionError("PDF conversion attempted a runtime download"),
                )
            )
            check(
                "PDF conversion exports mocked Markdown",
                cli._convert_with_docling(str(valid_pdf), ".pdf") == "# PDF\n",
            )
        check("PDF converter receives artifacts_path", fake_options.instances[-1].artifacts_path == artifacts)
        check("PDF converter disables OCR", fake_options.instances[-1].do_ocr is False)
        check("PDF converter enables table structure", fake_options.instances[-1].do_table_structure is True)
        check("PDF converter selects PDF format", fake_converter.instances[-1].options is not None)
        check("PDF format option receives pipeline options", fake_pdf_format.instances[-1].pipeline_options is fake_options.instances[-1])

        # Office conversion does not require the PDF artifact env or PDF options.
        os.environ.pop(cli.DOCLING_ARTIFACTS_PATH, None)
        downloaded = workdir / "document"
        minimal_ooxml(cli, downloaded, ".docx")
        modules, fake_converter, fake_options, fake_pdf_format = mocked_docling(
            cli, converter_options=False, markdown="# Office\n"
        )
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(sys.modules, modules))
            check(
                "Office conversion works without PDF artifacts",
                cli._convert_with_docling(str(downloaded), ".docx") == "# Office\n",
            )
        check("Office converter does not receive PDF options", fake_converter.instances[-1].options is None)
        check("Office conversion did not construct PDF options", not fake_options.instances)

        # Even parser argument errors must not echo a presigned URL.
        output = io.StringIO()
        error = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            check("invalid argument exits safely", cli.main(["--unknown", valid_url]) == cli.EXIT_INVALID_INPUT)
        check("URL is absent from stdout", valid_url not in output.getvalue())
        check("URL is absent from stderr", valid_url not in error.getvalue())
        check("URL is absent from ParseDocumentError", valid_url not in expect_error(
            "argument error is URL-free", lambda: cli.parse_args([valid_url, "a.txt", "extra"])
        ))

        try:
            cli.extension_for_filename("notes.txt")
        except cli.ParseDocumentError as exc:
            check("unsupported extension reports safely", str(exc) == "unsupported file format")
        else:
            raise AssertionError("unsupported extension was accepted")
    finally:
        if previous_host is None:
            os.environ.pop(cli.PARSE_DOCUMENT_ALLOWED_HOST, None)
        else:
            os.environ[cli.PARSE_DOCUMENT_ALLOWED_HOST] = previous_host
        os.environ.pop("PARSE_DOCUMENT_WORKDIR", None)
        os.environ.pop(cli.DOCLING_ARTIFACTS_PATH, None)
        shutil.rmtree(workdir, ignore_errors=True)

    print("parse-document unit tests passed (URL, ZIP metadata, limits, and safe errors).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
