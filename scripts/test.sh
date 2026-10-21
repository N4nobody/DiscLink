#!/bin/bash
# Full test run without a drive:
#   1. unit tests (swift run udfkit-tests)
#   2. end-to-end: images formatted by macOS's own newfs_udf, written by udfdisc while
#      simulating packet writing (CD-RW/DVD±RW) and write-once discs (CD-R/DVD-R), then
#      checked with fsck_udf, our own checker, and by mounting them with macOS.
# Usage: scripts/test.sh [work dir]   (default: a temporary folder, deleted afterwards)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# If Xcode is installed but its license hasn't been accepted yet, fall back to the Command Line Tools.
if ! xcrun --show-sdk-version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if [ $# -ge 1 ]; then W="$1"; mkdir -p "$W"; else W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; fi
cd "$W"
B="$ROOT/.build/debug/udfdisc"
export UDFDISC_LANG=zh   # the checks below look for Chinese output

pass=0; failn=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; failn=$((failn+1)); }
t()      { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }      # must succeed
t_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }      # must fail
same()   { cmp -s "$1" "$2"; }

echo "== 编译"
(cd "$ROOT" && swift build 2>&1 | grep -E "error:" && exit 1 || true)
echo "== 单元测试"
if (cd "$ROOT" && swift run -q udfkit-tests) | sed 's/^/  /'; then ok "单元测试全部通过"; else bad "单元测试有失败"; fi

# Test data: tiny (stored inside the file entry), medium, large, Chinese names, a folder of 122 files.
mkdir -p "src/资料/子文件夹"
echo "hello" > src/tiny.txt
echo "changed" > src/tiny2.txt
head -c 150000 /dev/urandom > src/medium.bin
head -c 25000000 /dev/urandom > src/large.bin
echo "中文内容" > "src/资料/说明 文档.txt"
head -c 70000 /dev/urandom > "src/资料/子文件夹/photo.jpg"
for i in $(seq 1 120); do echo "$i" > "src/资料/子文件夹/file_$i.txt"; done

# MARK: image helpers

format_image() {  # name, size MB, newfs_udf args...
    local name=$1 mb=$2; shift 2
    rm -f "$name.img"; mkfile -n "${mb}m" "$name.img"
    local dev
    dev=$(diskutil image attach --noMount "$name.img" 2>/dev/null | awk '{print $1}' | head -1)
    /sbin/newfs_udf -b 2048 "$@" "$dev" | sed -nE 's/.*last written block address: ([0-9]+).*/\1/p'
    diskutil eject "$dev" >/dev/null
}

# A fresh write-once disc: format, then cut the image down to what was recorded.
format_write_once() {  # name, size MB
    local last
    last=$(format_image "$1" "$2" -r 2.01 -m blk -t wo -v "$1")
    python3 -c "import os,sys; os.truncate(sys.argv[1], (int(sys.argv[2]) + 1) * 2048)" "$1.img" "$last"
}

DEV=""; MP=""
mount_image() {  # image [readonly]
    DEV=""; MP=""
    local out
    out=$(diskutil image attach ${2:+-readOnly} "$1" 2>&1) || return 1
    DEV=$(echo "$out" | awk '{print $1}' | head -1)
    MP=$(mount | grep -F "$DEV on" | sed -E 's/.* on (.*) \(udf.*/\1/' || true)
    [ -n "$MP" ] && [ -d "$MP" ]
}

# diskutil returns before the disk-image helper has written everything back to the file.
unmount_image() {  # image
    diskutil eject "$DEV" >/dev/null
    local path; path="$(pwd)/$1"
    for _ in $(seq 1 50); do hdiutil info | grep -qF "$path" || break; sleep 0.2; done
    sleep 1
}

check_fs() {  # image: fsck_udf where it understands the layout, plus our own checker
    if /sbin/fsck_udf -n "$1" >fsck.log 2>&1; then ok "fsck_udf 检查通过"
    elif grep -q "Unknown partition type" fsck.log; then echo "  - fsck_udf 不支持这种分区，只用自带检查"
    else bad "fsck_udf 报错：$(tail -3 fsck.log | tr '\n' ' ')"; fi
    if "$B" check "$1" >check.log 2>&1; then ok "自带一致性检查通过"
    else bad "一致性检查：$(grep 问题 check.log | head -3 | tr '\n' ' ')"; fi
}

read_back() {  # image: compare what we wrote through our own reader
    rm -rf out && mkdir out
    "$B" get "$1" /资料 out/资料 && "$B" get "$1" /large.bin out/large.bin && "$B" get "$1" /tiny.txt out/tiny.txt
    if same out/large.bin src/large.bin && same out/tiny.txt src/tiny2.txt; then ok "读回内容一致"; else bad "读回内容不一致"; fi
    if [ "$(ls out/资料/子文件夹 | wc -l | tr -d ' ')" = "120" ]; then ok "子文件夹剩 120 项"; else bad "子文件夹数量不对"; fi
}

compare_in_macos() {  # mounted at $MP
    if same "$MP/large.bin" src/large.bin && same "$MP/tiny.txt" src/tiny2.txt; then ok "macOS 挂载后文件一致"; else bad "macOS 挂载后文件不一致"; fi
    if [ ! -e "$MP/资料/子文件夹/file_7.txt" ] && [ -d "$MP/空文件夹" ]; then ok "macOS 看到删除和新文件夹"; else bad "macOS 目录状态不对"; fi
    if same "$MP/资料/说明 文档.txt" "src/资料/说明 文档.txt"; then ok "macOS 读中文文件名"; else bad "macOS 中文文件名"; fi
}

# MARK: rewritable discs

rewritable_suite() {  # image, packet size
    local img=$1 pk=$2
    local O=(--packet "$pk" --strict)
    echo "== $img（可擦写盘，模拟每包 $pk 块，严格对齐）"
    t "写入小文件（内嵌在文件条目里）" "$B" put "${O[@]}" "$img" src/tiny.txt /tiny.txt
    t "写入 150KB 文件" "$B" put "${O[@]}" "$img" src/medium.bin /medium.bin
    t "写入 25MB 文件" "$B" put "${O[@]}" "$img" src/large.bin /large.bin
    t "写入含 122 个文件的中文文件夹" "$B" put "${O[@]}" "$img" "src/资料" "/资料"
    t "新建文件夹" "$B" mkdir "${O[@]}" "$img" /空文件夹
    t_fail "同名文件不覆盖" "$B" put "${O[@]}" "$img" src/tiny.txt /tiny.txt
    t "覆盖文件" "$B" put --overwrite "${O[@]}" "$img" src/tiny2.txt /tiny.txt
    t "删除文件" "$B" rm "${O[@]}" "$img" /medium.bin
    t "删除子文件夹里的文件" "$B" rm "${O[@]}" "$img" "/资料/子文件夹/file_7.txt"
    read_back "$img"
    check_fs "$img"

    if ! mount_image "$img"; then bad "macOS 无法挂载镜像"; return; fi
    compare_in_macos
    if [ -e "$MP/medium.bin" ]; then bad "macOS 仍看到已删除的文件"; else ok "macOS 看不到已删除的文件"; fi
    # Reverse direction: macOS writes, we read, then we keep writing.
    echo "from macOS" > "$MP/mac.txt"; sync
    unmount_image "$img"
    local got=0
    for _ in $(seq 1 30); do   # the image helper can take a few seconds to write back
        "$B" get "$img" /mac.txt out/mac.txt 2>/dev/null && grep -q "from macOS" out/mac.txt && { got=1; break; }
        sleep 0.5
    done
    if [ $got = 1 ]; then ok "读取 macOS 写入的文件"; else bad "读取 macOS 写入的文件"; fi
    t "在 macOS 写过之后继续写入" "$B" put "${O[@]}" "$img" src/tiny.txt /after-mac.txt
    t "删除 macOS 写入的文件" "$B" rm "${O[@]}" "$img" /mac.txt
    check_fs "$img"
}

format_image plain 200 -r 2.01 -v PLAIN >/dev/null;                       rewritable_suite plain.img 16
format_image spar16 200 -r 2.01 -m blk -d -p 16 -t ow -v SPAR16 >/dev/null; rewritable_suite spar16.img 16
format_image spar32 200 -r 2.01 -m blk -d -p 32 -t ow -v SPAR32 >/dev/null; rewritable_suite spar32.img 32
format_image r150 200 -r 1.50 -m blk -d -p 32 -t ow -v R150 >/dev/null;     rewritable_suite r150.img 32

echo "== 可擦写盘空间不足"
format_image small 4 -r 2.01 -v SMALL >/dev/null
t_fail "空间不足时报错" "$B" put small.img src/large.bin /large.bin
check_fs small.img
t "报错后还能继续写" "$B" put small.img src/tiny.txt /t.txt

# MARK: write-once discs

write_once_suite() {  # image, link blocks (7 after every write on CD-R; 16 after each flush on DVD-R), alignment
    local img=$1 link=$2 align=${3:-1}
    local O=(--sequential --link "$link" --align "$align")
    if [ "$align" -gt 1 ]; then echo "== $img（一次性写入盘，模拟 DVD-R：刷新时补满 $align 扇区一组，再跳过 $link 个链接扇区）"
    else echo "== $img（一次性写入盘，模拟 CD-R：每次写入后跳过 $link 个扇区）"; fi
    if "$B" info "$img" | grep -q "写入：不可用"; then ok "不用追加模式打开时不允许写"; else bad "没有拦截写入"; fi
    t "追加小文件" "$B" put "${O[@]}" "$img" src/tiny.txt /tiny.txt
    t "追加 25MB 文件" "$B" put "${O[@]}" "$img" src/large.bin /large.bin
    t "追加含 122 个文件的中文文件夹" "$B" put "${O[@]}" "$img" "src/资料" "/资料"
    t "新建文件夹" "$B" mkdir "${O[@]}" "$img" /空文件夹
    t "覆盖文件（写新版本）" "$B" put --overwrite "${O[@]}" "$img" src/tiny2.txt /tiny.txt
    t "删除文件" "$B" rm "${O[@]}" "$img" "/资料/子文件夹/file_7.txt"
    local before after
    before=$(stat -f %z "$img")
    "$B" put "${O[@]}" "$img" src/large.bin /large2.bin >/dev/null 2>&1 || true
    "$B" put "${O[@]}" "$img" src/large.bin /large3.bin >/dev/null 2>&1 || true
    t_fail "空间用完时报错" "$B" put "${O[@]}" "$img" src/large.bin /large4.bin
    after=$(stat -f %z "$img")
    if [ "$after" -ge "$before" ]; then ok "只在末尾追加，从不缩小"; else bad "镜像变小了"; fi
    check_fs "$img"
    read_back "$img"
    if [ "$align" -gt 1 ]; then
        local vat; vat=$("$B" info "${O[@]}" "$img" | sed -nE 's/VAT 位置：扇区 ([0-9]+)/\1/p')
        if [ -n "$vat" ] && [ $(( (vat + 1) % align )) = 0 ]; then ok "VAT 落在 $align 扇区一组的最后一个扇区（Windows 要求）"; else bad "VAT 位置没对齐：$vat"; fi
    fi
    cp "$img" mounted.img
    if mount_image mounted.img readonly; then compare_in_macos; unmount_image mounted.img
    else bad "macOS 无法挂载一次性写入镜像"; fi
}

format_write_once cdr 80;  write_once_suite cdr.img 7
format_write_once dvdr 80; write_once_suite dvdr.img 16 16

# MARK: read-only layouts

echo "== UDF 2.50"
format_image r250 200 -r 2.50 -v R250 >/dev/null
if "$B" info r250.img | grep -q "写入：不可用"; then ok "2.50 只读"; else bad "2.50 未拦截写入"; fi

echo
echo "通过 $pass，失败 $failn"
[ "$failn" = 0 ]
