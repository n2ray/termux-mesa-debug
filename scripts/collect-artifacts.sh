#!/bin/bash
# Usage: collect-artifacts.sh <variant> <termux-output-dir> <dist-dir>
# Copies the built .debs and builds tmd-vulkan-<variant>.tar.gz containing
#   <variant>/libvulkan_freedreno.so
#   <variant>/freedreno_icd.json   (library_path -> $PREFIX/opt/tmd/<variant>/...)
# meant to be unpacked into $PREFIX/opt/tmd/ on the phone.
set -euo pipefail
variant=$1 out=$2 dist=$3
PREFIX=/data/data/com.termux/files/usr

mkdir -p "$dist/debs"
cp -v "$out"/*.deb "$dist/debs/"

deb=$(ls "$dist"/debs/mesa-vulkan-icd-freedreno_*_aarch64.deb | head -n1)
tmp=$(mktemp -d)
dpkg-deb -x "$deb" "$tmp"
so="$tmp$PREFIX/lib/libvulkan_freedreno.so"
json=$(ls "$tmp$PREFIX"/share/vulkan/icd.d/freedreno_icd*.json | head -n1)
test -f "$so"
echo "original ICD json:"; cat "$json"; echo

stage=$(mktemp -d)
mkdir -p "$stage/$variant"
cp "$so" "$stage/$variant/"
sed "s|\"library_path\": *\"[^\"]*\"|\"library_path\": \"$PREFIX/opt/tmd/$variant/libvulkan_freedreno.so\"|" \
  "$json" > "$stage/$variant/freedreno_icd.json"
grep -q "$PREFIX/opt/tmd/$variant/libvulkan_freedreno.so" "$stage/$variant/freedreno_icd.json"
echo "side-by-side ICD json:"; cat "$stage/$variant/freedreno_icd.json"; echo

# Proof that the instrumentation is in the binary.
if grep -c "TMD_DEBUG" "$so" >/dev/null; then echo "TMD strings present"; else echo "TMD strings MISSING"; exit 1; fi
sha256sum "$stage/$variant/libvulkan_freedreno.so" | tee "$stage/$variant/SHA256SUMS"
tar -C "$stage" -czf "$dist/tmd-vulkan-$variant.tar.gz" "$variant"
tar -tzvf "$dist/tmd-vulkan-$variant.tar.gz"
