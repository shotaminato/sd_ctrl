# SD Card Block Write Script

Pack a text file into 512-byte blocks and raw-read or raw-write an SD card on Windows. This is for an FPGA SD controller that accesses sectors directly, without a filesystem.

| File | Description |
| --- | --- |
| `write_sd_blocks.py` | Script |
| `sample.txt` | Example text input |
| `sample.hex` | Example hex input |

## Requirements

- Windows
- Python 3
- Run disk read/write from an **elevated** PowerShell or terminal
- **Do not format the card.** The script does not use FAT; it accesses sectors by LBA
- Close Explorer windows that have the target disk open before running

Examples below are run from the repository root.

## List disks

```powershell
python tb/scripts/write_sd_blocks.py --list
```

Use the `Number` column as `--disk`. Access to disk 0 (usually the Windows system disk) is refused.

## Write

The text is padded to a 512-byte boundary and written from the given LBA. A UTF-8 BOM is stripped by default. Padding bytes are `0x00`.

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt --disk 3 --start-lba 0
```

The script asks you to retype the disk number before overwriting. Use `--force` to skip that prompt. Add `--verify` to read the blocks back immediately and compare.

`--start-lba 0` overwrites the first sector, so any existing partition table or filesystem is destroyed. If Windows then asks to format the card, that is expected for FPGA raw-block use.

## Read

Use `--read` to check what was written. Administrator rights are required. Read does not overwrite, so it does not ask you to retype the disk number.

Compare against the original input (recommended):

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 tb/scripts/sample.txt
```

Passing the same input used for writing compares the encoded image with the data on disk. A match prints `Read data matches the encoded input.` The block contents are also shown as a hex dump.

Read a given number of blocks:

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 --start-lba 0 --blocks 1
```

Save the dump to a file:

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 --blocks 1 -o tb/scripts/dump.bin
```

## Example session

Write `sample.txt` to disk 3 at LBA 0, then read it back and compare:

```
PS C:\Users\Shota\HOME\repo\sd_ctrl> python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt --disk 3 --start-lba 0
Input      : C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.txt
Format     : text
Payload    : 58 byte(s)
Block size : 512 byte(s)
Image      : 512 byte(s) / 1 block(s)
First 64 bytes: 73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65 73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D 20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00
Wrote image: C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.bin
Target disk 3: NORELSYS 1081CS0 USB Device
  Size      : 59.68 GiB
  Interface : USB
  Media     : Removable Media
  Device    : \\.\PHYSICALDRIVE3
Type the disk number 3 to overwrite it, or press Enter to abort: 3
Dismounting D: ...
Dismounted D:
Wrote 512 byte(s) / 1 block(s) at LBA 0.
PS C:\Users\Shota\HOME\repo\sd_ctrl> python tb/scripts/write_sd_blocks.py --read --disk 3 tb/scripts/sample.txt
Input      : C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.txt
Format     : text
Payload    : 58 byte(s)
Block size : 512 byte(s)
Image      : 512 byte(s) / 1 block(s)
First 64 bytes: 73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65 73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D 20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00
No mounted volume letters; accessing the physical drive directly.
Target disk 3: NORELSYS 1081CS0 USB Device
  Size      : 59.68 GiB
  Interface : USB
  Media     : Removable Media
  Device    : \\.\PHYSICALDRIVE3
Read 512 byte(s) / 1 block(s) at LBA 0.
00000000  73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65  |sd_ctrl block te|
00000010  73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42  |st..0123456789AB|
00000020  43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D  |CDEF..hello from|
00000030  20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00  | windows........|
00000040  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000050  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000060  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000070  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000080  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000090  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000A0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000B0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000C0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000D0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000E0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000F0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000100  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000110  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000120  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000130  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000140  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000150  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000160  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000170  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000180  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000190  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001A0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001B0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001C0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001D0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001E0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001F0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
Read data matches the encoded input.
```

## Encode only

Omit `--disk` to create a `.bin` without writing the SD card. Administrator rights are not required.

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt
```

The default output is a `.bin` next to the input (`tb/scripts/sample.bin` in this example). Override it with `-o`.

## Hex input

Spaces, comments (`#` / `//`), and `0x` prefixes are ignored.

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.hex --format hex --disk 3 --start-lba 0
```

## Options

| Option | Description |
| --- | --- |
| `--list` | List physical disks |
| `--disk N` | Target disk number |
| `--start-lba LBA` | First LBA to read or write (default: 0) |
| `--read` | Read instead of write |
| `--blocks N` | Blocks to read (default: 1, or the encoded input size) |
| `--format {text,hex}` | How to interpret the input (default: `text`) |
| `--block-size BYTES` | Block size (default: 512) |
| `--pad-byte BYTE` | Padding byte (default: `0x00`) |
| `-o PATH` | Encoded `.bin` on write, dump path on read |
| `--verify` | Read back after write and compare |
| `--force` | Skip the disk-number confirmation on write |
| `--keep-bom` | Keep a leading UTF-8 BOM in text input |

# SDカード ブロック書き込みスクリプト

Windows 上でテキストを 512 バイトブロックのバイナリに詰め、SD カードへ生書き込み／読み出しするためのスクリプトです。FPGA の SD コントローラがファイルシステムを介さずセクタを読む用途向けです。

| ファイル | 内容 |
| --- | --- |
| `write_sd_blocks.py` | 本体 |
| `sample.txt` | テキスト入力の例 |
| `sample.hex` | 16 進入力の例 |

## 前提

- Windows
- Python 3
- ディスクへの読み書きは **管理者権限** の PowerShell またはターミナルで実行する
- **フォーマットは不要**。FAT などは使わず、LBA 単位でセクタへ直接アクセスする
- 対象ディスクをエクスプローラーで開いている場合は閉じてから実行する

リポジトリのルートから実行する例です。

## ディスク一覧

```powershell
python tb/scripts/write_sd_blocks.py --list
```

`Number` 列が `--disk` に渡す番号です。ディスク 0（通常は Windows のシステムディスク）へのアクセスは拒否します。

## 書き込み

テキストを 512 バイト境界にパディングし、指定 LBA から書き込みます。UTF-8 BOM は既定で除去します。不足分は `0x00` で埋めます。

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt --disk 3 --start-lba 0
```

確認のため、対象ディスク番号の再入力を求めます。省略する場合は `--force` を付けます。書き込み直後に読み戻して比較する場合は `--verify` を付けます。

`--start-lba 0` は先頭セクタから上書きするため、既存のパーティション表やファイルシステムは消えます。書き込み後に Windows が「フォーマットしますか」と出しても、FPGA 向けの生書き込みとしては正常です。

## 読み出し

書き込めたかの確認には `--read` を使います。管理者権限が必要です。読み出しは上書きしないので、ディスク番号の再入力はありません。

書いたデータと照合する（推奨）:

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 tb/scripts/sample.txt
```

書き込み時と同じ入力を渡すと、エンコード結果と読み出し結果を比較します。一致すれば `Read data matches the encoded input.` と出ます。ブロック内容は hex dump でも表示します。

指定ブロック数だけ読む:

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 --start-lba 0 --blocks 1
```

読み出した内容をファイルに保存する:

```powershell
python tb/scripts/write_sd_blocks.py --read --disk 3 --blocks 1 -o tb/scripts/dump.bin
```

## 実行例

`sample.txt` をディスク 3 の LBA 0 へ書き込み、読み戻して照合した例です。

```
PS C:\Users\Shota\HOME\repo\sd_ctrl> python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt --disk 3 --start-lba 0
Input      : C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.txt
Format     : text
Payload    : 58 byte(s)
Block size : 512 byte(s)
Image      : 512 byte(s) / 1 block(s)
First 64 bytes: 73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65 73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D 20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00
Wrote image: C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.bin
Target disk 3: NORELSYS 1081CS0 USB Device
  Size      : 59.68 GiB
  Interface : USB
  Media     : Removable Media
  Device    : \\.\PHYSICALDRIVE3
Type the disk number 3 to overwrite it, or press Enter to abort: 3
Dismounting D: ...
Dismounted D:
Wrote 512 byte(s) / 1 block(s) at LBA 0.
PS C:\Users\Shota\HOME\repo\sd_ctrl> python tb/scripts/write_sd_blocks.py --read --disk 3 tb/scripts/sample.txt
Input      : C:\Users\Shota\HOME\repo\sd_ctrl\tb\scripts\sample.txt
Format     : text
Payload    : 58 byte(s)
Block size : 512 byte(s)
Image      : 512 byte(s) / 1 block(s)
First 64 bytes: 73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65 73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D 20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00
No mounted volume letters; accessing the physical drive directly.
Target disk 3: NORELSYS 1081CS0 USB Device
  Size      : 59.68 GiB
  Interface : USB
  Media     : Removable Media
  Device    : \\.\PHYSICALDRIVE3
Read 512 byte(s) / 1 block(s) at LBA 0.
00000000  73 64 5F 63 74 72 6C 20 62 6C 6F 63 6B 20 74 65  |sd_ctrl block te|
00000010  73 74 0D 0A 30 31 32 33 34 35 36 37 38 39 41 42  |st..0123456789AB|
00000020  43 44 45 46 0D 0A 68 65 6C 6C 6F 20 66 72 6F 6D  |CDEF..hello from|
00000030  20 77 69 6E 64 6F 77 73 0D 0A 00 00 00 00 00 00  | windows........|
00000040  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000050  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000060  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000070  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000080  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000090  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000A0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000B0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000C0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000D0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000E0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000000F0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000100  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000110  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000120  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000130  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000140  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000150  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000160  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000170  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000180  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
00000190  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001A0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001B0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001C0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001D0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001E0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
000001F0  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
Read data matches the encoded input.
```

## バイナリ化だけ

`--disk` を省略すると、SD カードへは書かず `.bin` だけ作ります。管理者権限は不要です。

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.txt
```

既定の出力は入力と同じ場所の `.bin`（この例では `tb/scripts/sample.bin`）です。`-o` で変更できます。

## 16 進入力

空白・コメント（`#` / `//`）・`0x` 接頭辞は無視します。

```powershell
python tb/scripts/write_sd_blocks.py tb/scripts/sample.hex --format hex --disk 3 --start-lba 0
```

## 主なオプション

| オプション | 説明 |
| --- | --- |
| `--list` | 物理ディスク一覧 |
| `--disk N` | 対象ディスク番号 |
| `--start-lba LBA` | 読み書きを開始する LBA（既定: 0） |
| `--read` | 書き込みではなく読み出し |
| `--blocks N` | 読み出すブロック数（既定: 1、入力ファイルがあればそのサイズ） |
| `--format {text,hex}` | 入力の解釈（既定: `text`） |
| `--block-size BYTES` | ブロックサイズ（既定: 512） |
| `--pad-byte BYTE` | 末尾パディング（既定: `0x00`） |
| `-o PATH` | 書き込み時はエンコード後の `.bin`、読み出し時はダンプ先 |
| `--verify` | 書き込み直後に読み戻して比較 |
| `--force` | 書き込み前の番号再入力を省略 |
| `--keep-bom` | テキスト先頭の UTF-8 BOM を残す |
