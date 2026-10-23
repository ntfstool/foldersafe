#!/bin/bash
# 跨客户端互通测试（规范 §10）：FolderSafe（Swift，fsvault）⇄ Cryptomator 官方库（Java，cryptomator/run.sh）。
# 用法: interop/run-interop.sh            全部在临时目录里跑，跑完删除；任何一步不一致就失败退出
# 1. FolderSafe 建库 → Cryptomator 读出的目录树 == 源目录
# 2. Cryptomator 建库 → FolderSafe 读出的目录树 == 源目录
# 3. Cryptomator 往 FolderSafe 的库里写（库里有 foldersafe/ 扩展目录）→ 两边读出一致，找回短语仍能打开
# 4. FolderSafe 往 Cryptomator 的库里写，并加上 foldersafe/ 找回短语 → 两边读出一致
# 5. 测试向量里的 L1 部分用 Cryptomator 官方库复核
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FS="$ROOT/client/foldersafe_apple_core/.build/release/fsvault"
CM="$ROOT/interop/cryptomator/run.sh"
PW="interop password 互通"

echo "▶ 构建 fsvault"
(cd "$ROOT/client/foldersafe_apple_core" && swift build -c release --product fsvault 2>&1 | tail -1)

W="$(mktemp -d -t fs-interop)"
trap 'rm -rf "$W"' EXIT

# 源目录：边界大小、深目录、长名、中文/emoji、NFD 名字、空目录、符号链接
make_tree() {
  local s="$1" tag="$2"
  mkdir -p "$s/a/b/c" "$s/空目录" "$s/中文 目录"
  : > "$s/empty.txt"
  printf x > "$s/one.bin"
  head -c 32768 /dev/urandom > "$s/a/exact-32768.bin"
  head -c 100000 /dev/urandom > "$s/a/b/c/100000.bin"
  echo "$tag" > "$s/中文 目录/你好 🔐.txt"
  echo "nfd $tag" > "$s/$(printf 'e\xcc\x81')-nfd.txt"
  echo "long $tag" > "$s/a/$(printf 'L%.0s' {1..230}).txt"
  mkdir "$s/$(printf 'D%.0s' {1..230})" && echo inner > "$s/$(printf 'D%.0s' {1..230})/inner.txt"
  ln -s "../中文 目录/你好 🔐.txt" "$s/a/link-to-file"
  ln -s "/absolute/target" "$s/abs-link"
}

same() {  # 比较两份 dump（按路径排序后逐项相同）
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
a, b = (sorted(json.load(open(f))["entries"], key=lambda e: e["path"]) for f in sys.argv[1:3])
if a != b:
    sa, sb = {json.dumps(e, sort_keys=True) for e in a}, {json.dumps(e, sort_keys=True) for e in b}
    print("✗", sys.argv[3]); [print("  only left :", e) for e in sorted(sa - sb)]; [print("  only right:", e) for e in sorted(sb - sa)]
    sys.exit(1)
print("✓", sys.argv[3], f"({len(a)} entries)")
PY
}

make_tree "$W/src1" one
make_tree "$W/src2" two
echo "extra from cryptomator" > "$W/src2/only-in-src2.txt"
"$FS" srcdump --source "$W/src1" > "$W/src1.json"

echo "▶ 1. FolderSafe 建库 → Cryptomator 读"
"$FS" create --vault "$W/fsv" --password "$PW" --source "$W/src1" --phrase-out "$W/fsv.phrase"
"$CM" dump --vault "$W/fsv" --password "$PW" > "$W/1.json"
same "$W/src1.json" "$W/1.json" "Cryptomator 读 FolderSafe 的库"

echo "▶ 2. Cryptomator 建库 → FolderSafe 读"
"$CM" create --vault "$W/cmv" --password "$PW" --source "$W/src1"
"$FS" dump --vault "$W/cmv" --password "$PW" > "$W/2.json"
same "$W/src1.json" "$W/2.json" "FolderSafe 读 Cryptomator 的库"

echo "▶ 3. Cryptomator 写入 FolderSafe 的库"
"$CM" write --vault "$W/fsv" --password "$PW" --source "$W/src2"
"$CM" dump --vault "$W/fsv" --password "$PW" > "$W/3a.json"
"$FS" dump --vault "$W/fsv" --password "$PW" > "$W/3b.json"
"$FS" dump --vault "$W/fsv" --phrase "$(cat "$W/fsv.phrase")" > "$W/3c.json"
same "$W/3a.json" "$W/3b.json" "写入后两边读出一致"
same "$W/3b.json" "$W/3c.json" "找回短语仍能打开"
grep -q only-in-src2 "$W/3b.json" && echo "✓ 新文件可见"

echo "▶ 4. FolderSafe 写入 Cryptomator 的库并加找回短语"
"$FS" write --vault "$W/cmv" --password "$PW" --source "$W/src2"
PHRASE="$("$FS" enable-recovery --vault "$W/cmv" --password "$PW")"
"$CM" dump --vault "$W/cmv" --password "$PW" > "$W/4a.json"
"$FS" dump --vault "$W/cmv" --phrase "$PHRASE" > "$W/4b.json"
same "$W/4a.json" "$W/4b.json" "加 foldersafe/ 后 Cryptomator 仍正常"

echo "▶ 5. 测试向量（L1）用 Cryptomator 官方库复核"
"$CM" verify-vectors --file "$ROOT/docs/spec/test-vectors/v1.json"

echo "全部通过"
