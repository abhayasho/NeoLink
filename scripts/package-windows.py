#!/usr/bin/env python3
"""Package an already-built Windows executable with its required runtime resources."""
import argparse
import hashlib
from pathlib import Path
import zipfile


def package(binary: Path, repository: Path, output: Path) -> None:
    # Fail before replacing an artifact if CI passed the wrong platform or omitted the Lua runtime.
    with binary.open("rb") as executable:
        if executable.read(2) != b"MZ":
            raise ValueError("Expected a Windows PE executable")
    editor = repository / "Resources" / "Editor"
    if not (editor / "neolink.lua").is_file():
        raise ValueError("Missing Resources/Editor/neolink.lua")
    icon = repository / "Resources" / "AppIcon.png"
    if not icon.is_file():
        raise ValueError("Missing Resources/AppIcon.png")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".zip.tmp")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(binary, "NeoLink/NeoLink.exe")
            for path in sorted(editor.rglob("*")):
                if path.is_file() and not path.is_symlink():
                    archive.write(path, "NeoLink/Resources/Editor/" + path.relative_to(editor).as_posix())
            archive.write(icon, "NeoLink/Resources/AppIcon.png")
            archive.write(repository / "LICENSE", "NeoLink/LICENSE")
            archive.writestr("NeoLink/README.txt", """NeoLink for Windows

The easiest way to install is NeoLink-Setup-x64.exe from the same release page, or in
PowerShell:  irm https://raw.githubusercontent.com/abhayasho/NeoLink/main/scripts/install.ps1 | iex
Either adds Start menu and desktop icons, "Open in NeoLink" on folders and a `neolink`
command, and installs Neovim, Git and ripgrep if they are missing.

To use this archive as it is: extract this entire folder, then open NeoLink.exe. Keep the
Resources folder beside the executable: it holds the editor configuration.

Optional tools, installed separately: Neovim (nvim.exe on PATH) for Vim editing and
language servers (without it, files open in the built-in text editor), Git, ripgrep,
language servers and coding-agent command-line tools. SSH and SFTP use Windows
OpenSSH; remote browsing needs key or agent authentication. PDFs open in your
system's PDF application.

This build is not code-signed; Windows SmartScreen may ask before the first launch.
Windows support is newer than macOS: please report problems on GitHub.
""")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    write_checksum(output)


def write_checksum(path: Path) -> Path:
    """`<sha256>  <name>` beside the file, as for the macOS download; scripts/install.ps1 checks it."""
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    checksum = path.with_name(path.name + ".sha256")
    checksum.write_text(f"{digest}  {path.name}\n", encoding="ascii", newline="\n")
    return checksum


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / "target/release/neolink.exe")
    parser.add_argument("--output", type=Path, default=root / "target/NeoLink-windows-x64.zip")
    parser.add_argument("--checksum-only", type=Path, help="only write the .sha256 of this file (the setup program)")
    args = parser.parse_args()
    if args.checksum_only:
        print(write_checksum(args.checksum_only))
        raise SystemExit
    package(args.binary, root, args.output)
    print(args.output)
