# partclone-to-vhdx

Convert a **Clonezilla / Partclone NTFS** image into a **dynamic VHDX** you can mount under Windows to copy files.

Targeted at the workflow: restore partition image → VHDX → `Mount-VHD` → browse/copy. It is **not** meant to produce a bootable VM disk.

## Requirements

- Windows 10/11 with **WSL2** and a default Linux distro (`wsl -u root` must work)
- Enough free space on the output drive for the restored used data (dynamic VHDX grows with used blocks, not the full virtual partition size)
- First run installs packages in WSL and may **build partclone 0.3.52** (XXH128). That needs network access inside WSL

Optional for `-Mount`:

- Hyper-V PowerShell module (`Mount-VHD`), usually present when Hyper-V or “Hyper-V Module for Windows PowerShell” is enabled
- Administrator rights (UAC prompt)

## Quick start

```powershell
cd path\to\partclone-to-vhdx

# Image folder or file from Clonezilla — VHDX is written next to it
.\Convert-PartcloneToVhdx.ps1 -ImagePath 'H:\backup\sda3.ntfs-ptcl-img'

# Explicit output + mount afterwards
.\Convert-PartcloneToVhdx.ps1 `
  -ImagePath 'H:\backup\nvme0n1p3.ntfs-ptcl-img' `
  -OutputPath 'H:\backup\nvme0n1p3.vhdx' `
  -Mount
```

Mount / unmount later (Admin PowerShell):

```powershell
Mount-VHD -Path 'H:\backup\sda3.vhdx'
Dismount-VHD -Path 'H:\backup\sda3.vhdx'
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-ImagePath` | Partclone image **file**, Clonezilla **folder**, or first split part (`*.aa`) |
| `-OutputPath` | Destination `.vhdx` (optional) |
| `-SkipToolSetup` | Skip `apt` / partclone build (tools already installed) |
| `-Mount` | Mount the VHDX under Windows when restore finishes |

## Supported inputs

- Uncompressed Partclone NTFS image (`*.ntfs-ptcl-img`)
- Clonezilla directory that contains that file (same name as the folder)
- Split images (`name.aa`, `name.ab`, …)
- Compressed single files: `.gz`, `.zst`, `.xz`

## What the script does

```text
Partclone image
      │
      ▼
parse header (exact device size)
      │
      ▼
qemu-img create dynamic VHDX  (partition size + 16 MiB GPT padding)
      │
      ▼
qemu-nbd attach → sgdisk GPT + one NTFS-type partition
      │
      ▼
partclone.ntfs -r  →  /dev/nbd0p1
      │
      ▼
optional NTFS read-only check → detach NBD
      │
      ▼
optional Mount-VHD + drive letter
```

Why WSL?

- Partclone and exact block restore are Linux-native
- Newer Clonezilla images often use **XXH128** checksums; the distro `partclone` package can be too old. The helper builds **0.3.52** with `libxxhash` when needed

## Disk space & RAM notes

- Prefer a dynamic VHDX: a ~900 GiB partition with ~80 GiB used typically yields an ~80–110 GiB file
- Large restores can be memory-hungry under WSL. If partclone dies with OOM, raise WSL memory in `%UserProfile%\.wslconfig`, then `wsl --shutdown`:

```ini
[wsl2]
memory=16GB
swap=8GB
```

## Manual equivalent (reference)

```bash
# inside WSL as root
qemu-img create -f vhdx -o subformat=dynamic /mnt/h/out.vhdx $((PART_BYTES + 16*1024*1024))
modprobe nbd max_part=8
qemu-nbd -c /dev/nbd0 -f vhdx /mnt/h/out.vhdx
sgdisk --zap-all /dev/nbd0
sgdisk -n 1:2048:+$((PART_BYTES/512)) -t 1:0700 /dev/nbd0
partclone.ntfs -r -s /path/to/image -o /dev/nbd0p1
qemu-nbd --disconnect /dev/nbd0
```

## Layout

```text
Convert-PartcloneToVhdx.ps1   # Windows entrypoint
wsl/restore-to-vhdx.sh        # restore pipeline run as root in WSL
README.md
```

## License

MIT
