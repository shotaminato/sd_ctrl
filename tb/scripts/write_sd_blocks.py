#!/usr/bin/env python3
"""Encode a text file into 512-byte SD blocks and read or write them on Windows."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

DEFAULT_BLOCK_SIZE = 512
UTF8_BOM = b"\xef\xbb\xbf"


class ScriptError(Exception):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read a text file as bytes, pack it into SD-card blocks "
            "(default 512 bytes), and read or write the image on a "
            "physical drive on Windows."
        )
    )
    parser.add_argument(
        "-l",
        "--list",
        action="store_true",
        help="list physical disks and exit",
    )
    parser.add_argument(
        "input",
        nargs="?",
        type=Path,
        help="source text file (or hex text with --format hex)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="destination .bin path (write: encoded image; read: dumped blocks)",
    )
    parser.add_argument(
        "--format",
        choices=("text", "hex"),
        default="text",
        help="text: use file bytes as the payload (default); hex: parse hex tokens",
    )
    parser.add_argument(
        "--keep-bom",
        action="store_true",
        help="keep a UTF-8 BOM if the text file starts with EF BB BF",
    )
    parser.add_argument(
        "--block-size",
        type=int,
        default=DEFAULT_BLOCK_SIZE,
        metavar="BYTES",
        help="logical block size in bytes (default: 512)",
    )
    parser.add_argument(
        "--pad-byte",
        type=lambda value: int(value, 0),
        default=0,
        metavar="BYTE",
        help="padding byte for the final partial block (default: 0x00)",
    )
    parser.add_argument(
        "--disk",
        type=int,
        metavar="N",
        help="physical disk number from --list; omit on write to create the .bin only",
    )
    parser.add_argument(
        "--start-lba",
        type=int,
        default=0,
        metavar="LBA",
        help="first logical block address to read or write (default: 0)",
    )
    parser.add_argument(
        "--read",
        action="store_true",
        help="read blocks from the disk instead of writing",
    )
    parser.add_argument(
        "--blocks",
        type=int,
        metavar="N",
        help="number of blocks to read (default: 1, or the encoded input size)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="skip the interactive confirmation before writing",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="read the written blocks back and compare them with the image",
    )
    args = parser.parse_args()

    if args.list and args.read:
        parser.error("--list and --read cannot be used together")
    if not args.list and not args.read and args.input is None:
        parser.error("input is required unless --list or --read is used")
    if args.read and args.disk is None:
        parser.error("--disk is required with --read")
    if args.block_size < 1:
        parser.error("--block-size must be >= 1")
    if args.blocks is not None and args.blocks < 1:
        parser.error("--blocks must be >= 1")
    if not 0 <= args.pad_byte <= 255:
        parser.error("--pad-byte must be in 0..255")
    if args.start_lba < 0:
        parser.error("--start-lba must be >= 0")
    return args


GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002
OPEN_EXISTING = 3
FILE_FLAG_WRITE_THROUGH = 0x80000000
FSCTL_LOCK_VOLUME = 0x00090018
FSCTL_DISMOUNT_VOLUME = 0x00090020
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


def decode_windows_output(data: bytes) -> str:
    if not data:
        return ""
    for encoding in ("utf-8-sig", "utf-8", "cp932", "mbcs"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def run_powershell(command: str) -> str:
    completed = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            command,
        ],
        check=False,
        capture_output=True,
    )
    stdout = decode_windows_output(completed.stdout)
    stderr = decode_windows_output(completed.stderr)
    if completed.returncode != 0:
        detail = (stderr or stdout).strip()
        raise ScriptError(detail or f"PowerShell command failed with {completed.returncode}")
    return stdout


def kernel32():
    dll = ctypes.WinDLL("kernel32", use_last_error=True)
    dll.CreateFileW.restype = ctypes.c_void_p
    dll.CreateFileW.argtypes = [
        ctypes.c_wchar_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
    ]
    dll.DeviceIoControl.restype = ctypes.c_int
    dll.DeviceIoControl.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    ]
    dll.CloseHandle.restype = ctypes.c_int
    dll.CloseHandle.argtypes = [ctypes.c_void_p]
    return dll


def win32_error() -> str:
    return f"Win32 error {ctypes.get_last_error()}"


def device_io_control(handle: int, control_code: int) -> bool:
    returned = ctypes.c_uint32(0)
    return bool(
        kernel32().DeviceIoControl(
            handle,
            control_code,
            None,
            0,
            None,
            0,
            ctypes.byref(returned),
            None,
        )
    )


def get_drive_letters(number: int) -> list[str]:
    try:
        raw = run_powershell(
            f"@(Get-Partition -DiskNumber {int(number)} -ErrorAction SilentlyContinue | "
            "Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter }) | "
            "ConvertTo-Json -Compress"
        ).strip()
    except ScriptError as exc:
        print(f"warning: could not query volume letters: {exc}")
        return []
    if not raw or raw == "null":
        return []
    data = json.loads(raw)
    if isinstance(data, str):
        data = [data]
    return [str(letter).strip() for letter in data if str(letter).strip()]


def lock_and_dismount_volumes(letters: list[str]) -> list[int]:
    handles = []
    k32 = kernel32()
    for letter in letters:
        path = f"\\\\.\\{letter}:"
        handle = k32.CreateFileW(
            path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_EXISTING,
            0,
            None,
        )
        if handle in (None, INVALID_HANDLE_VALUE):
            print(f"warning: could not open {path} ({win32_error()})")
            continue
        if not device_io_control(handle, FSCTL_LOCK_VOLUME):
            print(f"warning: could not lock {path} ({win32_error()})")
        if not device_io_control(handle, FSCTL_DISMOUNT_VOLUME):
            print(f"warning: could not dismount {path} ({win32_error()})")
        else:
            print(f"Dismounted {letter}:")
        handles.append(handle)
    return handles


def close_volume_handles(handles: list[int]) -> None:
    k32 = kernel32()
    for handle in handles:
        k32.CloseHandle(handle)


def list_physical_disks() -> list[dict]:
    raw = run_powershell(
        "Get-CimInstance Win32_DiskDrive | "
        "Select-Object Index,Model,Size,InterfaceType,MediaType,DeviceID | "
        "ConvertTo-Json -Compress"
    ).strip()
    if not raw or raw == "null":
        return []
    data = json.loads(raw)
    if isinstance(data, dict):
        data = [data]
    return sorted(data, key=lambda disk: int(disk["Index"]))


def print_disk_table(disks: list[dict]) -> None:
    if not disks:
        print("No physical disks were found.")
        return

    headers = ("Number", "Model", "SizeGiB", "Interface", "Media", "DeviceId")
    rows = []
    for disk in disks:
        rows.append(
            (
                str(disk["Index"]),
                str(disk.get("Model") or "").strip(),
                f"{int(disk.get('Size') or 0) / (1024 ** 3):.2f}",
                str(disk.get("InterfaceType") or ""),
                str(disk.get("MediaType") or ""),
                str(disk.get("DeviceID") or ""),
            )
        )

    widths = [len(header) for header in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt(row: tuple[str, ...]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row))

    print(fmt(headers))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print(fmt(row))
    print()
    print("Use the Number column as --disk. Disk 0 is blocked as a safety check.")


def parse_hex_text(text: str) -> bytes:
    cleaned_lines = []
    for line in text.splitlines():
        line = re.sub(r"#.*$", "", line)
        line = re.sub(r"//.*$", "", line)
        cleaned_lines.append(line)
    joined = re.sub(r"0x", "", " ".join(cleaned_lines), flags=re.IGNORECASE)
    joined = re.sub(r"[^0-9A-Fa-f]", "", joined)
    if not joined:
        raise ScriptError("Hex input does not contain any hexadecimal digits.")
    if len(joined) % 2:
        raise ScriptError(f"Hex input has an odd number of digits ({len(joined)}).")
    return bytes.fromhex(joined)


def payload_from_file(path: Path, fmt: str, keep_bom: bool) -> bytes:
    raw = path.read_bytes()
    if fmt == "hex":
        return parse_hex_text(raw.decode("utf-8"))
    if raw.startswith(UTF8_BOM) and not keep_bom:
        print("Dropped UTF-8 BOM from the text file.")
        return raw[len(UTF8_BOM) :]
    return raw


def pack_sd_blocks(payload: bytes, block_size: int, pad_byte: int) -> bytes:
    if not payload:
        return bytes([pad_byte]) * block_size
    remainder = len(payload) % block_size
    pad_length = 0 if remainder == 0 else block_size - remainder
    return payload + bytes([pad_byte]) * pad_length


def hex_preview(data: bytes, count: int = 64) -> str:
    preview = data[:count]
    return " ".join(f"{byte:02X}" for byte in preview)


def print_hexdump(data: bytes, origin: int = 0) -> None:
    for offset in range(0, len(data), 16):
        chunk = data[offset : offset + 16]
        hex_part = " ".join(f"{byte:02X}" for byte in chunk)
        ascii_part = "".join(chr(byte) if 32 <= byte < 127 else "." for byte in chunk)
        print(f"{origin + offset:08X}  {hex_part:<47}  |{ascii_part}|")


def is_windows() -> bool:
    return os.name == "nt"


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except AttributeError:
        return False


def require_windows(action: str) -> None:
    if not is_windows():
        raise ScriptError(f"{action} is only supported on Windows.")


def disk_record(number: int) -> dict:
    for disk in list_physical_disks():
        if int(disk["Index"]) == number:
            return disk
    raise ScriptError(f"Physical disk {number} was not found. Run --list first.")


def print_target_disk(disk: dict) -> None:
    number = int(disk["Index"])
    size_gib = int(disk.get("Size") or 0) / (1024 ** 3)
    print(f"Target disk {number}: {str(disk.get('Model') or '').strip()}")
    print(f"  Size      : {size_gib:.2f} GiB")
    print(f"  Interface : {disk.get('InterfaceType')}")
    print(f"  Media     : {disk.get('MediaType')}")
    print(f"  Device    : {disk.get('DeviceID')}")


def confirm_target_disk(disk: dict, force: bool) -> None:
    number = int(disk["Index"])
    print_target_disk(disk)
    if not force:
        answer = input(
            f"Type the disk number {number} to overwrite it, or press Enter to abort: "
        )
        if answer.strip() != str(number):
            raise ScriptError("Write aborted.")


def refuse_system_disk(number: int) -> None:
    if number == 0:
        raise ScriptError("Refusing to access disk 0 (usually the Windows system disk).")


@contextmanager
def physical_disk_access(number: int):
    require_windows("Accessing a physical disk")
    if not is_admin():
        raise ScriptError(
            "Accessing a physical disk requires an elevated prompt (Run as administrator)."
        )
    refuse_system_disk(number)
    disk = disk_record(number)
    handles: list[int] = []
    try:
        letters = get_drive_letters(number)
        if letters:
            print("Dismounting " + ", ".join(f"{letter}:" for letter in letters) + " ...")
            handles = lock_and_dismount_volumes(letters)
        else:
            print("No mounted volume letters; accessing the physical drive directly.")
        yield disk
    finally:
        close_volume_handles(handles)


def open_physical_drive(number: int, write: bool) -> int:
    import msvcrt

    path = rf"\\.\PhysicalDrive{number}"
    access = GENERIC_READ | (GENERIC_WRITE if write else 0)
    flags = FILE_FLAG_WRITE_THROUGH if write else 0
    handle = kernel32().CreateFileW(
        path,
        access,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        None,
        OPEN_EXISTING,
        flags,
        None,
    )
    if handle in (None, INVALID_HANDLE_VALUE):
        raise ScriptError(f"Could not open {path}: {win32_error()}")
    os_flags = os.O_RDWR if write else os.O_RDONLY
    return msvcrt.open_osfhandle(int(handle), os_flags)


def disk_size_bytes(number: int) -> int:
    return int(disk_record(number).get("Size") or 0)


def check_disk_range(number: int, offset: int, nbytes: int, action: str) -> None:
    size = disk_size_bytes(number)
    if size > 0 and offset + nbytes > size:
        raise ScriptError(
            f"{action} exceeds disk size: offset={offset}, bytes={nbytes}, disk={size}"
        )


def write_physical_drive(
    number: int,
    start_lba: int,
    block_size: int,
    image: bytes,
    verify: bool,
) -> None:
    offset = start_lba * block_size
    check_disk_range(number, offset, len(image), "Write")
    fd = open_physical_drive(number, write=True)
    try:
        try:
            os.lseek(fd, offset, os.SEEK_SET)
            written = os.write(fd, image)
            if written != len(image):
                raise ScriptError(f"Short write: {written} of {len(image)} byte(s).")
            try:
                os.fsync(fd)
            except OSError:
                pass
        except OSError as exc:
            raise ScriptError(f"Write failed: {exc}") from exc
        print(
            f"Wrote {len(image)} byte(s) / {len(image) // block_size} block(s) "
            f"at LBA {start_lba}."
        )
        if verify:
            try:
                os.lseek(fd, offset, os.SEEK_SET)
                read_back = os.read(fd, len(image))
            except OSError as exc:
                raise ScriptError(f"Verify read failed: {exc}") from exc
            if read_back != image:
                for i, (expected, actual) in enumerate(zip(image, read_back)):
                    if expected != actual:
                        raise ScriptError(
                            f"Verify mismatch at byte offset {i}: "
                            f"wrote 0x{expected:02X}, read 0x{actual:02X}."
                        )
                raise ScriptError(
                    f"Verify read returned {len(read_back)} byte(s), expected {len(image)}."
                )
            print("Verify succeeded.")
    finally:
        os.close(fd)


def read_physical_drive(
    number: int,
    start_lba: int,
    block_size: int,
    nbytes: int,
) -> bytes:
    offset = start_lba * block_size
    check_disk_range(number, offset, nbytes, "Read")
    fd = open_physical_drive(number, write=False)
    try:
        try:
            os.lseek(fd, offset, os.SEEK_SET)
            data = os.read(fd, nbytes)
        except OSError as exc:
            raise ScriptError(f"Read failed: {exc}") from exc
        if len(data) != nbytes:
            raise ScriptError(f"Short read: {len(data)} of {nbytes} byte(s).")
        return data
    finally:
        os.close(fd)


def encode_image(args: argparse.Namespace, write_bin: bool = True) -> tuple[Path | None, bytes, bytes]:
    input_path = args.input.resolve()
    if not input_path.is_file():
        raise ScriptError(f"Input file not found: {input_path}")

    output_path = args.output
    if write_bin:
        if output_path is None:
            output_path = input_path.with_suffix(".bin")
        else:
            output_path = output_path.expanduser().resolve()

    payload = payload_from_file(input_path, args.format, args.keep_bom)
    image = pack_sd_blocks(payload, args.block_size, args.pad_byte)
    print(f"Input      : {input_path}")
    print(f"Format     : {args.format}")
    print(f"Payload    : {len(payload)} byte(s)")
    print(f"Block size : {args.block_size} byte(s)")
    print(f"Image      : {len(image)} byte(s) / {len(image) // args.block_size} block(s)")
    print(f"First {min(64, len(image))} bytes: {hex_preview(image)}")

    if write_bin:
        assert output_path is not None
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(image)
        print(f"Wrote image: {output_path}")
    return output_path, payload, image


def write_disk(args: argparse.Namespace, image: bytes) -> None:
    require_windows("Accessing a physical disk")
    if not is_admin():
        raise ScriptError(
            "Accessing a physical disk requires an elevated prompt (Run as administrator)."
        )
    refuse_system_disk(args.disk)
    confirm_target_disk(disk_record(args.disk), args.force)
    with physical_disk_access(args.disk):
        write_physical_drive(
            args.disk,
            args.start_lba,
            args.block_size,
            image,
            args.verify,
        )


def compare_readback(expected: bytes, actual: bytes) -> None:
    if actual == expected:
        print("Read data matches the encoded input.")
        return
    limit = min(len(expected), len(actual))
    for i in range(limit):
        if expected[i] != actual[i]:
            raise ScriptError(
                f"Read mismatch at byte offset {i}: "
                f"expected 0x{expected[i]:02X}, read 0x{actual[i]:02X}."
            )
    raise ScriptError(
        f"Read length mismatch: expected {len(expected)} byte(s), got {len(actual)}."
    )


def read_disk(args: argparse.Namespace) -> None:
    expected = None
    if args.input is not None:
        _, _, expected = encode_image(args, write_bin=False)

    if args.blocks is not None:
        nbytes = args.blocks * args.block_size
    elif expected is not None:
        nbytes = len(expected)
    else:
        nbytes = args.block_size

    if expected is not None and nbytes < len(expected):
        raise ScriptError(
            f"--blocks is too small to compare the encoded input "
            f"({len(expected) // args.block_size} block(s))."
        )

    with physical_disk_access(args.disk) as disk:
        print_target_disk(disk)
        data = read_physical_drive(
            args.disk,
            args.start_lba,
            args.block_size,
            nbytes,
        )

    print(
        f"Read {len(data)} byte(s) / {len(data) // args.block_size} block(s) "
        f"at LBA {args.start_lba}."
    )
    print_hexdump(data, origin=args.start_lba * args.block_size)

    if args.output is not None:
        output_path = args.output.expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(data)
        print(f"Wrote dump: {output_path}")

    if expected is not None:
        compare_readback(expected, data[: len(expected)])


def main() -> int:
    args = parse_args()
    try:
        if args.list:
            require_windows("Listing physical disks")
            print_disk_table(list_physical_disks())
            return 0

        if args.read:
            read_disk(args)
            return 0

        _, _, image = encode_image(args)
        if args.disk is None:
            print("No --disk was given, so the SD card was not written.")
            return 0

        write_disk(args, image)
        return 0
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
