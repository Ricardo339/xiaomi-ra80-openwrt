# 小米 AX3000（RA80 V2）OpenWrt 移植

> **测试范围声明：本仓库的方案只在作者本人的一台 RA80 V2 上验证过。**
> 不同生产批次、不同闪存/交换机/Wi-Fi 模块的机器可能不适用。
> 按本文操作有变砖风险，请先完整备份，风险自负。本仓库已公开；
> 请不要把设备唯一数据（`0:APPSBLENV`、`0:ART`、`bdata`）提交进来。

## 设备信息

| 项目 | 值 |
|---|---|
| 型号 | 小米 AX3000（RA80 V2） |
| SoC | Qualcomm IPQ5018（machid `0x8040002`） |
| RAM | 256 MB |
| Flash | 128 MB SPI-NAND，**Winbond W25N01GWZEIG**（WSON8 8×6mm，1.8V，JEDEC `EF BA 21`） |
| 交换机 | Motorcomm YT9215S（MDIO1，地址 `0x1d`，5 个内置 GbE PHY） |
| Wi-Fi | IPQ5018 2.4G + QCN6122 5G |
| UART | 115200 8N1，由引导器配置 |

分区（MIBIB，128 KiB 块，21 项）：

```
mtd0  0:SBL1        0x000000  512K
mtd1  0:MIBIB       0x080000  512K
mtd2  0:BOOTCONFIG  0x100000  256K
mtd3  0:BOOTCONFIG1 0x140000  256K
mtd4  0:QSEE        0x180000  1M
mtd5  0:QSEE_1      0x280000  1M
mtd6  0:DEVCFG      0x380000  256K
mtd7  0:DEVCFG_1    0x3C0000  256K
mtd8  0:CDT         0x400000  256K
mtd9  0:CDT_1       0x440000  256K
mtd10 0:APPSBLENV   0x480000  512K
mtd11 0:APPSBL      0x500000  1.25M
mtd12 0:APPSBL_1    0x640000  1.25M
mtd13 0:ART         0x780000  1M
mtd14 0:TRAINING    0x880000  512K
mtd15 bdata         0x900000  512K
mtd16 crash         0x980000  512K
mtd17 crash_syslog  0xA00000  512K
mtd18 rootfs        0xA80000  30M
mtd19 rootfs_1      0x2880000 30M
mtd20 overlay       0x4680000 57.5M
```

## 已验证的功能

| 功能 | 状态 | 说明 |
|---|---|---|
| YT9215S DSA 驱动 | ✅ | lan1/lan2/lan3/wan 端口创建；**lan3 实插验证** DHCP/IPv4/IPv6 |
| REVSGMII CPU 链路 | ✅ | SERDES0 用 REVSGMII（mode=1），`EXT_CPU_PORT=0xc008` |
| tag_yt921x 双释放修复 | ✅ | 修复 `kfree_skb` 与 DSA core 的 double free panic |
| LuCI | ✅ | `http://192.168.2.1`，uhttpd 监听 80（默认 root 空密码） |
| LED | ✅ | 开机红灯；WAN 未连接 net 红灯，连接后白灯 |
| Wi-Fi 2.4G + 5G | ✅ | phy0 ch1 20MHz；phy1 ch36 80MHz；5G 需要 949 低内存补丁 |
| NAND 安装 | ✅ | OpenWrt 写入 mtd19（rootfs_1），U-Boot 手动引导；断电默认回原厂 |

## 未验证 / 已知限制

| 项目 | 状态 | 说明 |
|---|---|---|
| 合并 rootfs/rootfs_1/overlay（117.5MB） | ❌ 未上机 | 只编译过镜像，未刷入；见 `ra80-openwrt/experimental/` |
| U-Boot 自动引导 | ❌ 未完成 | 需要改 U-Boot；作者在验证前把设备刷砖了 |
| lan1 / lan2 / wan 实插 | ⚠️ 未逐一测试 | 驱动创建了端口，只实测了 lan3 |
| Wi-Fi 吞吐、2.5G 实际协商速率 | ⚠️ 未测 | 没有 iperf3 / 链路速率记录 |
| 其他批次硬件 | ⚠️ 未知 | 只测过一台；闪存/交换机批次可能不同 |

## 设备当前状态

作者这台机器在 2026-11-14 尝试在自制 U-Boot 中执行 `saveenv` 时，env 偏移补丁计算错误
（按 64 KiB 块计算，实际 128 KiB），擦除了 `0x500000~0x580000`，覆盖 `0:APPSBL`
的前 512 KiB（ELF 头），SBL1 无法加载 → **硬砖**（无串口、无灯、无链路）。

原因和恢复方法见 `ra80-recovery/RECOVERY.md`；原厂分区备份只在作者本地保存，
不随仓库提供（`0:APPSBLENV` 含 SN/云密钥，`0:ART`/`bdata` 含 MAC 与校准）。
这是 U-Boot 操作造成的，与本仓库的 OpenWrt 方案无关。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `ra80-openwrt/` | 放进 OpenWrt 构建树的定制文件（DTS、驱动补丁、ath11k 补丁、板级文件） |
| `ra80-openwrt/experimental/` | 未验证的合并分区 DTS，仅作参考 |
| `ra80-firmware/` | 补丁后的 Wi-Fi BDF（原始厂商固件未入库） |
| `ra80-recovery/` | 变砖原因与恢复说明（不含厂商 bootloader 备份） |
| `tools/` | BDF 打包工具、board-2 JSON、`bd-patch.py` |
| `docs/A-INVESTIGATION.md` | 移植过程记录（含失败尝试与验证输出） |
| `docs/RELEASE-v0.1.0.md` | v0.1.0 发布说明 |
| `setup-tree.sh` | 把本仓库的定制文件复制进 WSL 构建树 |

二进制产物（initramfs、UBI kernel/rootfs、ath11k 模块、board-2）放在
GitHub Release **v0.1.0**，不占仓库体积；原始分区备份也不入库。

## 快速使用

1. **先备份**：在本地完整备份 `0:APPSBL`、`0:APPSBLENV`、`0:ART`、`bdata`（作者的备份不随仓库提供）。
2. **构建**：按 `ra80-openwrt/README.md` 把文件放进 `qosmio/openwrt-ipq` 25.12-nss 树。
3. **验证**：先用 initramfs 通过 U-Boot TFTP 启动，确认 LAN/LuCI/Wi-Fi。
4. **装 NAND**：见 `docs/A-INVESTIGATION.md` 第 19 节（ubiformat mtd19）。
5. **不要改 U-Boot**，尤其不要 `saveenv`——作者的机器就是这样砖的。

## 关键补丁

| 文件 | 作用 |
|---|---|
| `patches-6.12/800-net-dsa-yt921x-ra80.patch` | yt921x DSA：REVSGMII、2500 速率、debugfs 寄存器接口 |
| `patches-6.12/801-net-dsa-tag-yt921x-fix-double-free.patch` | tag 驱动不再重复释放 skb |
| `package/kernel/mac80211/patches/ath11k/949-wifi-ath11k-reduce-ring-sizes-for-lowmem.patch` | 256MB 机器上 5G 的 order-8 DMA 分配失败修复 |
| `ipq50xx/base-files/etc/hotplug.d/iface/30-net-led` | WAN 红/白灯逻辑 |

## 重要警告

- 本方案**只在作者的一台 RA80 V2 上测试过**，不保证其他机器可用。
- 刷机前必须完整备份；`0:APPSBLENV`、`0:ART`、`bdata` 是每台机器唯一的数据（本仓库不含这些分区）。
- 不要公开 `printenv` / `fw_printenv` 输出（含 Wi-Fi 密码、云 key、序列号、管理密码哈希）。
- 不要照抄作者的 U-Boot env 偏移修改；128 KiB 块下 `+4` 块正好落在 `0:APPSBL` 起始。
