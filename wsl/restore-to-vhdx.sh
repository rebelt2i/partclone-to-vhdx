#!/usr/bin/env bash
# Restore a Clonezilla/Partclone NTFS image into a dynamic VHDX (via qemu-nbd).
# Invoked by Convert-PartcloneToVhdx.ps1 as root inside WSL.
#
# Env / args:
#   $1  IMAGE_KIND   file | split
#   $2  IMAGE        WSL path to image file, or split prefix (without .aa)
#   $3  OUTPUT       WSL path to destination .vhdx
#   $4  SKIP_SETUP   0|1

set -euo pipefail

IMAGE_KIND="${1:?IMAGE_KIND required}"
IMAGE="${2:?IMAGE path required}"
OUTPUT="${3:?OUTPUT vhdx path required}"
SKIP_SETUP="${4:-0}"

PARTCLONE_BIN=""
NBD_DEV="${NBD_DEV:-/dev/nbd0}"
GPT_PAD_BYTES=$((16 * 1024 * 1024))
# SOURCE_MODE: file | stream-file | stream-split
SOURCE_MODE="file"
COMPRESS_CMD=()
SPLIT_PARTS=()
HEADER_FILE=""

log() { printf '\n==> %s\n' "$*"; }

ensure_tools() {
  log "Ensuring qemu / gdisk / build deps"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq qemu-utils gdisk parted ntfs-3g xxd python3 \
    build-essential autoconf automake libtool pkg-config \
    libntfs-3g-dev uuid-dev libssl-dev libxxhash-dev \
    zlib1g-dev libzstd-dev gettext autopoint git ca-certificates \
    zstd xz-utils gzip binutils

  # ntfs-3g-dev package name differs across distros
  apt-get install -y -qq ntfs-3g-dev 2>/dev/null || true

  PARTCLONE_BIN=""
  if [[ -x /usr/local/sbin/partclone.ntfs ]]; then
    PARTCLONE_BIN=/usr/local/sbin/partclone.ntfs
  elif command -v partclone.ntfs >/dev/null 2>&1; then
    PARTCLONE_BIN="$(command -v partclone.ntfs)"
  fi

  need_build=0
  if [[ -z "$PARTCLONE_BIN" ]]; then
    need_build=1
  elif ! strings "$PARTCLONE_BIN" 2>/dev/null | grep -q 'XXH128'; then
    echo "Partclone at $PARTCLONE_BIN lacks XXH128 — building 0.3.52+"
    need_build=1
  fi

  if [[ "$need_build" == "1" ]]; then
    log "Building partclone 0.3.52 with XXH128 support"
    cd /tmp
    rm -rf partclone-build
    git clone --depth 1 --branch 0.3.52 https://github.com/Thomas-Tsai/partclone.git partclone-build
    cd partclone-build
    ./autogen
    ./configure --enable-ntfs --disable-ncurses --disable-extfs --disable-hfsp \
      --disable-apfs --disable-btrfs --disable-f2fs --disable-xfs
    make -j"$(nproc)"
    # Prefer installing binaries; fall back to full install
    if ! make install-exec; then
      make install
    fi
    PARTCLONE_BIN=/usr/local/sbin/partclone.ntfs
    hash -r
  fi

  [[ -x "$PARTCLONE_BIN" ]] || { echo "partclone.ntfs not found" >&2; exit 1; }
  echo "Using $PARTCLONE_BIN"
  "$PARTCLONE_BIN" -v || true
}

detect_source() {
  case "$IMAGE_KIND" in
    file)
      case "$IMAGE" in
        *.gz)
          SOURCE_MODE="stream-file"
          COMPRESS_CMD=(gzip -dc "$IMAGE")
          gzip -dc "$IMAGE" | head -c 512 > /tmp/ptcl-hdr.bin
          HEADER_FILE=/tmp/ptcl-hdr.bin
          ;;
        *.zst)
          SOURCE_MODE="stream-file"
          COMPRESS_CMD=(zstd -dc "$IMAGE")
          zstd -dc "$IMAGE" | head -c 512 > /tmp/ptcl-hdr.bin
          HEADER_FILE=/tmp/ptcl-hdr.bin
          ;;
        *.xz)
          SOURCE_MODE="stream-file"
          COMPRESS_CMD=(xz -dc "$IMAGE")
          xz -dc "$IMAGE" | head -c 512 > /tmp/ptcl-hdr.bin
          HEADER_FILE=/tmp/ptcl-hdr.bin
          ;;
        *)
          SOURCE_MODE="file"
          HEADER_FILE="$IMAGE"
          [[ -f "$HEADER_FILE" ]] || { echo "Image not found: $HEADER_FILE" >&2; exit 1; }
          ;;
      esac
      ;;
    split)
      shopt -s nullglob
      SPLIT_PARTS=( "${IMAGE}".a[a-z] )
      shopt -u nullglob
      [[ ${#SPLIT_PARTS[@]} -gt 0 ]] || { echo "Split parts not found for prefix: $IMAGE" >&2; exit 1; }
      echo "Split parts (${#SPLIT_PARTS[@]}): ${SPLIT_PARTS[*]}"
      SOURCE_MODE="stream-split"
      head -c 512 "${SPLIT_PARTS[0]}" > /tmp/ptcl-hdr.bin
      HEADER_FILE=/tmp/ptcl-hdr.bin
      ;;
    *)
      echo "Unknown IMAGE_KIND=$IMAGE_KIND" >&2
      exit 1
      ;;
  esac
}

parse_size() {
  log "Parsing Partclone header for device size"
  PART_BYTES="$(python3 - "$HEADER_FILE" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as f:
    d = f.read(256)
magic = d[0:15]
if magic != b"partclone-image":
    print(f"Warning: unexpected magic {magic!r}", file=sys.stderr)
# image_head_v2 layout used by partclone 0.3.x:
# device_size u64 @0x34, totalblock u64 @0x3c, usedblocks u64 @0x4c, block_size u32 @0x54
device_size = struct.unpack_from("<Q", d, 0x34)[0]
total = struct.unpack_from("<Q", d, 0x3c)[0]
used = struct.unpack_from("<Q", d, 0x4c)[0]
bs = struct.unpack_from("<I", d, 0x54)[0]
if device_size <= 0 or device_size > 64 * (1024**4):
    raise SystemExit(f"Unplausible device_size={device_size}")
print(
    f"device_size={device_size} ({device_size/1024**3:.2f} GiB) "
    f"total_blocks={total} used_blocks={used} block_size={bs}",
    file=sys.stderr,
)
print(device_size)
PY
)"
  if (( PART_BYTES % 512 != 0 )); then
    echo "device_size $PART_BYTES is not 512-byte aligned" >&2
    exit 1
  fi
  PART_SECTORS=$((PART_BYTES / 512))
  VHDX_BYTES=$((PART_BYTES + GPT_PAD_BYTES))
  echo "PART_BYTES=$PART_BYTES PART_SECTORS=$PART_SECTORS VHDX_BYTES=$VHDX_BYTES"
}

create_and_partition() {
  log "Creating dynamic VHDX and GPT partition"
  modprobe nbd max_part=8
  qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sleep 1
  rm -f "$OUTPUT"
  mkdir -p "$(dirname "$OUTPUT")"
  qemu-img create -f vhdx -o subformat=dynamic "$OUTPUT" "$VHDX_BYTES"
  qemu-nbd -c "$NBD_DEV" -f vhdx "$OUTPUT"
  sleep 1
  sgdisk --zap-all "$NBD_DEV"
  sgdisk -n "1:2048:+${PART_SECTORS}" -t 1:0700 -c 1:partclone-ntfs "$NBD_DEV"
  partprobe "$NBD_DEV" 2>/dev/null || true
  sleep 1
  for _ in $(seq 1 20); do
    [[ -b "${NBD_DEV}p1" ]] && break
    sleep 0.5
  done
  [[ -b "${NBD_DEV}p1" ]] || { echo "Partition node ${NBD_DEV}p1 missing" >&2; exit 1; }
  ACTUAL="$(blockdev --getsize64 "${NBD_DEV}p1")"
  echo "ACTUAL=$ACTUAL EXPECTED=$PART_BYTES"
  if [[ "$ACTUAL" != "$PART_BYTES" ]]; then
    echo "Partition size mismatch" >&2
    exit 1
  fi
  lsblk "$NBD_DEV"
}

restore_image() {
  log "Restoring Partclone image (this can take a long time)"
  INFO_BIN="$(dirname "$PARTCLONE_BIN")/partclone.info"
  if [[ -x "$INFO_BIN" && "$SOURCE_MODE" == "file" ]]; then
    "$INFO_BIN" -s "$IMAGE" || true
  fi

  # Cleanup on failure so the VHDX is not left attached.
  trap 'qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true' EXIT

  case "$SOURCE_MODE" in
    file)
      "$PARTCLONE_BIN" -r --read-direct-io --write-direct-io -z 524288 \
        -s "$IMAGE" -o "${NBD_DEV}p1"
      ;;
    stream-file)
      "${COMPRESS_CMD[@]}" | "$PARTCLONE_BIN" -r --read-direct-io --write-direct-io -z 524288 \
        -s - -o "${NBD_DEV}p1"
      ;;
    stream-split)
      cat "${SPLIT_PARTS[@]}" | "$PARTCLONE_BIN" -r --read-direct-io --write-direct-io -z 524288 \
        -s - -o "${NBD_DEV}p1"
      ;;
    *)
      echo "Unknown SOURCE_MODE=$SOURCE_MODE" >&2
      exit 1
      ;;
  esac
}

verify_and_detach() {
  log "Verifying NTFS and detaching NBD"
  mkdir -p /mnt/partclone-to-vhdx-check
  if mount -t ntfs-3g -o ro "${NBD_DEV}p1" /mnt/partclone-to-vhdx-check; then
    echo "Top-level entries:"
    ls /mnt/partclone-to-vhdx-check | head -20 || true
    df -h /mnt/partclone-to-vhdx-check || true
    umount /mnt/partclone-to-vhdx-check
  else
    echo "Warning: NTFS mount check failed — VHDX may still be usable under Windows." >&2
  fi
  qemu-nbd --disconnect "$NBD_DEV"
  trap - EXIT
  sync
  qemu-img info "$OUTPUT"
  ls -lh "$OUTPUT"
  echo "DONE_OUTPUT=$OUTPUT"
}

if [[ "$SKIP_SETUP" != "1" ]]; then
  ensure_tools
else
  if [[ -x /usr/local/sbin/partclone.ntfs ]]; then
    PARTCLONE_BIN=/usr/local/sbin/partclone.ntfs
  else
    PARTCLONE_BIN="$(command -v partclone.ntfs || true)"
  fi
  [[ -n "$PARTCLONE_BIN" ]] || { echo "partclone.ntfs missing (omit -SkipToolSetup)" >&2; exit 1; }
fi

detect_source
parse_size
create_and_partition
restore_image
verify_and_detach
