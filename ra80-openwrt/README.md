# RA80 V2 OpenWrt 集成包

> **基线：`qosmio/openwrt-ipq` 25.12-nss（作者的构建树）。**
> 换用其他 OpenWrt 树时，文件路径、FIT config 名、包名都可能不同，需要自行适配。
>
> **测试范围：只在作者本人的一台 RA80 V2 上验证过。** 不同批次硬件可能不适用。
> 本目录中的合并分区 DTS（`experimental/`）**未上机验证**。

## 1. 文件对应关系

| 本仓库路径 | 复制到构建树的位置 |
|---|---|
| `target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-ra80-v2.dts` | 同路径 |
| `target/linux/qualcommax/patches-6.12/800-net-dsa-yt921x-ra80.patch` | 同路径 |
| `target/linux/qualcommax/patches-6.12/801-net-dsa-tag-yt921x-fix-double-free.patch` | 同路径 |
| `package/kernel/mac80211/patches/ath11k/949-wifi-ath11k-reduce-ring-sizes-for-lowmem.patch` | 同路径 |
| `target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/iface/30-net-led` | 同路径 |
| `target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata` | 同路径（含 `xiaomi,ra80-v2` 分支） |
| `target/linux/qualcommax/ipq50xx/base-files/etc/board.d/02_network` | 同路径（含 `xiaomi,ra80-v2` 分支） |
| `target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh` | 同路径（含 `xiaomi,ra80-v2` 分支） |
| `target/linux/qualcommax/image/ipq50xx.mk` | 同路径（含 `Device/xiaomi_ra80-v2`） |
| `package/firmware/ipq-wifi/Makefile` | 同路径（含 `xiaomi_ra80` 包） |
| `package/firmware/ipq-wifi/files/board-xiaomi_ra80.ipq5018` | 同路径（2.4G board-2.bin） |
| `package/firmware/ipq-wifi/files/board-xiaomi_ra80.qcn6122` | 同路径（5G board-2.bin） |

也可以直接运行仓库根目录的 `setup-tree.sh`（默认构建树路径
`/root/openwrt-ipq-25.12-nss`，可用 `T=` 覆盖）。

## 2. 设备定义

`image/ipq50xx.mk` 中的关键内容：

```makefile
define Device/xiaomi_ra80-v2
	$(call Device/FitImageLzma)
	$(call Device/UbiFit)
	DEVICE_VENDOR := Xiaomi
	DEVICE_MODEL := Router AX3000 (RA80 V2)
	DEVICE_DTS_CONFIG := config@mp03.3
	SOC := ipq5018
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	IMAGE_SIZE := 29696k
	NAND_SIZE := 128m
	DEVICE_PACKAGES := ath11k-firmware-ipq5018-qcn6122 \
		ipq-wifi-xiaomi_ra80
endef
TARGET_DEVICES += xiaomi_ra80-v2
```

`IMAGE_SIZE` 对应原厂 mtd18 `rootfs` 的 30MB 分区（29696k = 29MB）；
**不要**在没有验证的情况下把它改成合并分区的 117MB。

## 3. 构建配置

以构建树的 `nss-setup/config-nss.seed` 为基础，至少确认：

```
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_xiaomi_ra80-v2=y
CONFIG_TARGET_PROFILE="DEVICE_xiaomi_ra80-v2"

CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_kmod-ath11k=y
CONFIG_PACKAGE_kmod-ath11k-ahb=y
CONFIG_PACKAGE_ipq-wifi-xiaomi_ra80=y
CONFIG_PACKAGE_ath11k-firmware-ipq5018-qcn6122=y
```

然后：

```bash
make defconfig
make -j$(nproc) V=s
```

产物：

```
bin/targets/qualcommax/ipq50xx/
  openwrt-qualcommax-ipq50xx-xiaomi_ra80-v2-initramfs-uImage.itb
  openwrt-qualcommax-ipq50xx-xiaomi_ra80-v2-squashfs-sysupgrade.bin
  openwrt-qualcommax-ipq50xx-xiaomi_ra80-v2-squashfs-factory.ubi
```

## 4. 关键改动说明

### 4.1 YT9215S DSA（800/801）

- RA80 V2 的交换机是 Motorcomm YT9215S，不是 V1 的 QCA8337。
- 现代 qca-ssdk 的 `port_mac_sel="QGMAC_PORT"` 走 SGMII PHY 角色，
  所以交换机侧必须用 **REVSGMII**（SERDES mode=1），不能再用 2500BASE-X。
- CPU 口需要 `EXT_CPU_PORT=0xc008`（TAG_EN | PORT_EN | port 8）。
- `tag_yt921x.c` 在错误路径里重复 `kfree_skb`，DSA core 会再释放一次，
  导致 slab double free / 重启；801 补丁改成只 `return NULL`。

### 4.2 Wi-Fi 低内存（949）

256MB 机器上 5G 失败不是“总内存不够”，而是
`ath11k_dp_link_desc_setup` 申请 order-8（1MB）连续 DMA 内存失败：
monitor desc 环 4096 × 128B + 128 > 512KB。
949 把该环降到 1024（order-6，256KB），并同步缩小其他大环。

### 4.3 LED

- DTS：`led-sys-red`/`led-net-red` 的 `default-state="on"`，GPIO 高电平点亮。
- `30-net-led`：`wan` ifup 时红灭白亮；ifdown/ifup-failed 时红亮白灭。

### 4.4 板级 BDF

- `ra80-firmware/bdwlan.b24.patched` / `bdwlan.b60.patched`：
  把 BDF 偏移 `0x45c` 的 `0x03` 改成 `0x00`，并重算 16-bit XOR 校验。
- 用 `tools/board-2-ra80-ipq5018-final.json`、`board-2-ra80-qcn6122-final.json`
  和 `tools/ath11k-bdencoder` 生成 `board-2` 文件（`bus=ahb`）。
- 生成的 `board-xiaomi_ra80.ipq5018` / `.qcn6122` 由 `ipq-wifi-xiaomi_ra80`
  安装到 `/lib/firmware/ath11k/.../board-2.bin`。

## 5. 验证范围（仅一台机器）

已验证：

- initramfs 启动、lan3 DHCP/IPv4/IPv6、LuCI、LED
- 2.4G（phy0 ch1）与 5G（phy1 ch36 80MHz）射频启动
- OpenWrt 安装到 mtd19（rootfs_1），U-Boot 手动引导
- 断电默认回原厂系统（mtd18 未被覆盖）

未验证：

- lan1 / lan2 / wan 实插
- Wi-Fi 吞吐、2.5G 实际协商速率
- 合并 rootfs/rootfs_1/overlay（`experimental/`，只编译过）
- U-Boot 自动引导（未完成；作者在验证前把设备刷砖了）

## 6. 不要做的事

- **不要 `saveenv`**：作者的自制 U-Boot 把 env 偏移算错了 4 个 128 KiB 块，
  正好写到 `0:APPSBL` 起始（0x500000），覆盖 U-Boot 前 512 KiB → 硬砖。
- 不要在没备份/没串口/没编程器兜底时改 U-Boot 或分区表。
- 不要公开 `printenv` / `fw_printenv` 输出（含 Wi-Fi 密码、云 key、序列号）。
- 不要把 `0:ART`、`bdata` 换成其他机器的数据（每台唯一）。

恢复方法见 `../ra80-recovery/RECOVERY.md`。
