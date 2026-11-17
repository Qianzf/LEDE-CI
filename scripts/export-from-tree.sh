#!/bin/sh
# 从本地 LEDE 工作树把「构建输入」同步到本仓库。
#
# 用法：
#   ./scripts/export-from-tree.sh /workspace/code/lede
#
# 同步内容：
#   <tree>/.config            -> config/jdcloud-be6500.config
#   <tree>/env/kernel-config  -> overlay/env/kernel-config
#   <tree>/files/             -> overlay/files/
#
# 原因：源仓库的 .gitignore 忽略了 /.config、/env、/files，它们不在源码仓库里，
# CI 只能从这里注入。
set -eu

tree=${1:-}
if [ -z "$tree" ] || [ ! -f "$tree/.config" ]; then
	echo "用法: $0 <本地 LEDE 树路径>" >&2
	exit 1
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
cfg=${2:-jdcloud-be6500.config}

install -D -m 644 "$tree/.config" "$repo/config/$cfg"
echo "config/$cfg             <- $tree/.config"

if [ -f "$tree/env/kernel-config" ]; then
	install -D -m 644 "$tree/env/kernel-config" "$repo/overlay/env/kernel-config"
	echo "overlay/env/kernel-config <- $tree/env/kernel-config"
fi

if [ -d "$tree/files" ]; then
	mkdir -p "$repo/overlay/files"
	rsync -a --delete "$tree/files/" "$repo/overlay/files/" 2>/dev/null || \
		cp -a "$tree/files/." "$repo/overlay/files/"
	echo "overlay/files/          <- $tree/files/"
fi

echo
echo "同步完成。检查差异后提交："
cd "$repo"
git status --short
