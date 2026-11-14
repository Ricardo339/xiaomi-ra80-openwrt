#!/bin/bash
# Copy the validated RA80 V2 integration files into an OpenWrt build tree.
# Default tree: /root/openwrt-ipq-25.12-nss  (override with T=...)
set -e

T=${T:-/root/openwrt-ipq-25.12-nss}
B=$(cd "$(dirname "$0")" && pwd)
R="$B/ra80-openwrt"

[ -d "$T" ] || { echo "build tree not found: $T (set T=...)"; exit 1; }

# 1. board DTS (validated: qcom,smem-part)
cp "$R/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-ra80-v2.dts" \
   "$T/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"

# 2. kernel patches 800/801
mkdir -p "$T/target/linux/qualcommax/patches-6.12"
cp "$R/target/linux/qualcommax/patches-6.12/"*.patch \
   "$T/target/linux/qualcommax/patches-6.12/"

# 3. ath11k low-memory patch 949
mkdir -p "$T/package/kernel/mac80211/patches/ath11k"
cp "$R/package/kernel/mac80211/patches/ath11k/949-"*.patch \
   "$T/package/kernel/mac80211/patches/ath11k/"

# 4. target base-files (LED, caldata, network, platform.sh)
cp -r "$R/target/linux/qualcommax/ipq50xx/." \
      "$T/target/linux/qualcommax/ipq50xx/"

# 5. device definition + ipq-wifi package + board-2 files
cp "$R/target/linux/qualcommax/image/ipq50xx.mk" \
   "$T/target/linux/qualcommax/image/"
mkdir -p "$T/package/firmware/ipq-wifi/files"
cp "$R/package/firmware/ipq-wifi/Makefile" \
   "$T/package/firmware/ipq-wifi/"
cp "$R/package/firmware/ipq-wifi/files/board-xiaomi_ra80."* \
   "$T/package/firmware/ipq-wifi/files/"

echo "=== installed ==="
ls -l "$T/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-ra80-v2.dts"
ls -l "$T/target/linux/qualcommax/patches-6.12/"800-*.patch "$T/target/linux/qualcommax/patches-6.12/"801-*.patch
ls -l "$T/package/kernel/mac80211/patches/ath11k/949-"*.patch
ls -l "$T/target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/iface/30-net-led"
ls -l "$T/package/firmware/ipq-wifi/files/"
grep -n "Device/xiaomi_ra80-v2" "$T/target/linux/qualcommax/image/ipq50xx.mk"
