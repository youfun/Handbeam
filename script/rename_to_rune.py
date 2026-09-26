#!/usr/bin/env python3
"""Rename Sigil → Rune across this checkout.

Does not touch Elixir's Kernel sigils (`sigil_s`, Credo StringSigils) or the
GitHub remote `github.com/youfun/sigil` (rename the repo separately).

  python3 script/rename_to_rune.py --dry-run
  python3 script/rename_to_rune.py --apply
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SKIP_DIR_NAMES = {
    ".git",
    "_build",
    "build",
    "deps",
    "node_modules",
    ".elixir_ls",
    "artifacts",
    ".zig-cache",
    "zig-out",
    "intermediates",
    "mix_toolchain",
    "jniLibs",
    ".fetch",
    "tmp",
    "cover",
    "doc",
}

SKIP_SUFFIXES = {".db", ".db-shm", ".db-wal", ".so", ".apk", ".beam", ".png", ".dex", ".class", ".jar", ".o"}

SKIP_RELATIVE = {
    Path("script/rename_to_rune.py"),
}

# Longest-first. Do not add a bare "sigil" token — that would smash Kernel
# sigil_s / StringSigils / Credo check names.
REPLACEMENTS: list[tuple[str, str]] = [
    ("SigilProbe", "RuneProbe"),
    ("SigilBridge", "RuneBridge"),
    ("SigilRender", "RuneRender"),
    ("SigilTextField", "RuneTextField"),
    ("SigilWeb", "RuneWeb"),
    ("SIGIL_PROBE", "RUNE_PROBE"),
    ("SIGIL_", "RUNE_"),
    ("sigil_probe", "rune_probe"),
    ("sigil_browser", "rune_browser"),
    ("sigil_notify", "rune_notify"),
    ("sigil_ios", "rune_ios"),
    ("sigil_web", "rune_web"),
    ("sigil_dev", "rune_dev"),
    ("sigil_test", "rune_test"),
    ("sigil_host", "rune_host"),
    ("sigil.pack_mix_toolchain", "rune.pack_mix_toolchain"),
    ("Mix.Tasks.Sigil", "Mix.Tasks.Rune"),
    (".sigil", ".rune"),
    ("libsigil", "librune"),
    ("SIGIL-", "RUNE-"),
    ("sigil-", "rune-"),
]

SIGIL_WORD = re.compile(r"(?<![A-Za-z0-9_])Sigil(?![A-Za-z0-9_])")
ATOM_SIGIL = re.compile(r"(?<![A-Za-z0-9_]):sigil(?![A-Za-z0-9_])")

PROTECT = [
    "github.com/youfun/sigil",
    "Credo.Check.Readability.StringSigils",
]

TEXT_SUFFIXES = {
    ".ex",
    ".exs",
    ".heex",
    ".eex",
    ".leex",
    ".sface",
    ".erl",
    ".hrl",
    ".c",
    ".h",
    ".m",
    ".mm",
    ".kt",
    ".kts",
    ".java",
    ".xml",
    ".gradle",
    ".properties",
    ".plist",
    ".pro",
    ".zig",
    ".md",
    ".txt",
    ".json",
    ".jsonc",
    ".yml",
    ".yaml",
    ".toml",
    ".css",
    ".js",
    ".ts",
    ".html",
    ".sh",
    ".bash",
    ".zsh",
    ".env",
    ".gitignore",
    ".dockerignore",
    ".editorconfig",
    ".tool-versions",
}

NAMELESS_TEXT = {
    "mix.exs",
    "mix.lock",
    "Dockerfile",
    "Makefile",
    "AGENTS.md",
    "README.md",
    "LICENSE",
    "NOTICE",
    ".gitignore",
    ".credo.exs",
    "mob.exs",
    "mob.exs.template",
}


def skip_dir(path: Path) -> bool:
    return path.name in SKIP_DIR_NAMES


def is_text_file(path: Path) -> bool:
    rel = path.relative_to(ROOT)
    if rel in SKIP_RELATIVE:
        return False
    if path.suffix.lower() in SKIP_SUFFIXES or path.name.endswith(".db-shm") or path.name.endswith(".db-wal"):
        return False
    if path.name in NAMELESS_TEXT or path.suffix.lower() in TEXT_SUFFIXES:
        return True
    return False


def protect(text: str) -> tuple[str, list[tuple[str, str]]]:
    holders: list[tuple[str, str]] = []
    for i, needle in enumerate(PROTECT):
        token = f"\x00PROT{i}\x00"
        if needle in text:
            text = text.replace(needle, token)
            holders.append((token, needle))
    return text, holders


def unprotect(text: str, holders: list[tuple[str, str]]) -> str:
    for token, needle in holders:
        text = text.replace(token, needle)
    return text


def rewrite_text(text: str) -> str:
    text, holders = protect(text)
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    text = SIGIL_WORD.sub("Rune", text)
    text = ATOM_SIGIL.sub(":rune", text)
    return unprotect(text, holders)


def rewrite_name(name: str) -> str:
    updated = rewrite_text(name)
    stem, suffix = os.path.splitext(name)
    if name == "sigil" or stem == "sigil":
        return "rune" + suffix
    return updated


def iter_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not skip_dir(Path(dirpath) / d)]
        for name in filenames:
            yield Path(dirpath) / name


def rewrite_file(path: Path, apply: bool) -> bool:
    if not is_text_file(path):
        return False
    try:
        raw = path.read_bytes()
    except OSError as exc:
        print(f"skip unreadable {path}: {exc}", file=sys.stderr)
        return False
    if b"\0" in raw[:8192]:
        return False
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    updated = rewrite_text(text)
    if updated == text:
        return False
    if apply:
        path.write_text(updated, encoding="utf-8")
    return True


def rename_tree(root: Path, apply: bool) -> list[tuple[Path, Path]]:
    """Rename files then directories, deepest first."""
    moves: list[tuple[Path, Path]] = []
    paths = [p for p in root.rglob("*") if not any(skip_dir(part) for part in p.parents)]
    # Also skip if any path part is a skipped dir name
    filtered = []
    for p in paths:
        if any(part in SKIP_DIR_NAMES for part in p.parts):
            continue
        filtered.append(p)

    files = [p for p in filtered if p.is_file()]
    dirs = [p for p in filtered if p.is_dir()]
    dirs.sort(key=lambda p: len(p.parts), reverse=True)

    for path in files + dirs:
        if path.suffix.lower() in SKIP_SUFFIXES or path.name.endswith(".db-shm") or path.name.endswith(".db-wal"):
            continue
        try:
            if path.relative_to(ROOT) in SKIP_RELATIVE:
                continue
        except ValueError:
            pass
        new_name = rewrite_name(path.name)
        if new_name == path.name:
            continue
        dest = path.with_name(new_name)
        moves.append((path, dest))
        if apply:
            if dest.exists():
                raise SystemExit(f"rename collision: {path} -> {dest}")
            path.rename(dest)
    return moves


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write changes (default is dry-run)")
    parser.add_argument("--dry-run", action="store_true", help="Report only (default)")
    args = parser.parse_args()
    apply = bool(args.apply)

    os.chdir(ROOT)
    changed_files = 0
    for path in iter_files(ROOT):
        rel = path.relative_to(ROOT)
        if rewrite_file(path, apply=apply):
            changed_files += 1
            print(f"{'write' if apply else 'edit '} {rel}")

    moves = rename_tree(ROOT, apply=apply)
    for src, dest in moves:
        print(f"{'mv   ' if apply else 'rename'} {src.relative_to(ROOT)} -> {dest.relative_to(ROOT)}")

    print(
        f"\n{'applied' if apply else 'dry-run'}: {changed_files} files rewritten, "
        f"{len(moves)} path renames"
    )
    if not apply:
        print("Re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
