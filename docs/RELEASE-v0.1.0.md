# RA80 V2 OpenWrt 验证版（单机测试）

> **测试范围：本 release 的方案只在作者本人的一台小米 AX3000（RA80 V2）上验证过。**
> 不同生产批次、不同闪存/交换机/Wi-Fi 模块的机器可能不适用。
> 刷机有变砖风险，请先完整备份，风险自负。

## 设备

- 小米 AX3000（RA80 V2）
- IPQ5018 + QCN6122（2.4G + 5G）+ Motorcomm YT9215S
- 256 MB RAM / 128 MB SPI-NAND（Winbond W25N01GWZEIG，WSON8 8×6，1.8V）

## 已验证

- **有线**：YT9215S DSA 驱动 + REVSGMII 修复；lan3 实插 DHCP / IPv4 / IPv6 正常
- **LuCI**：`http://192.168.2.1`（root 空密码）
- **LED**：开机红灯；WAN 未连接 net 红灯，连接后白灯
- **Wi-Fi**：2.4G phy0 ch1；5G phy1 ch36 80MHz（5G 需要 949 低内存补丁）
- **NAND**：OpenWrt 写入 mtd19（rootfs_1），U-Boot 手动引导；断电默认回原厂

## 未验证

- lan1 / lan2 / wan 实插
- Wi-Fi 吞吐、2.5G 实际协商速率
- 合并 rootfs/rootfs_1/overlay 为 117.5MB（只编译过，未上机）
- U-Boot 自动引导（未完成；作者在验证前把设备刷砖了）

## 资产说明

| 文件 | 说明 |
|---|---|
| `openwrt-...-initramfs-uImage.itb` | 已验证的 initramfs，可用 U-Boot `tftpboot` 启动 |
| `openwrt-...-ubi-kernel.bin` | 写入 mtd19 UBI `kernel` 卷的 kernel（已验证） |
| `openwrt-...-ubi-rootfs.bin` | 写入 mtd19 UBI `rootfs` 卷的 rootfs（已验证） |
| `ath11k-6.12.91-lowmem.ko` | 5G 低内存修复模块（`DP_*_RING_SIZE` 缩小，已验证） |
| `ath11k_ahb-6.12.91-lowmem.ko` | 同上，AHB 总线模块 |
| `qmi_helpers-6.12.91.ko` | 同上，QMI helpers |
| `SHA256SUMS` | 以上文件的 SHA-256 |

模块对应内核 **6.12.91**。`ubi-rootfs.bin` 里的 ath11k 模块**不含** 949 补丁，
所以刷完 rootfs 后要把这三个 `.ko` 覆盖到 `/lib/modules/6.12.91/` 并重启
（ath11k 卸载后 Q6 无法重新启动），否则 5G 会报 order-8 分配失败。

board-2 文件不单独放进 release，源码仓库里已有：
`ra80-openwrt/package/firmware/ipq-wifi/files/board-xiaomi_ra80.*`。

## 安装到 NAND（已验证路径）

`sysupgrade.bin` 未通过完整 sysupgrade 流程验证，因此没有作为本 release 的资产。
已验证的做法是把 kernel/rootfs 直接写入 UBI 卷，见仓库
`docs/A-INVESTIGATION.md` 第 19 节：

```
ubiformat /dev/mtd19 -y
ubiattach -m 19 -d 0
ubimkvol /dev/ubi0 -N kernel -s 4372252
ubimkvol /dev/ubi0 -N rootfs -s 12362752
ubimkvol /dev/ubi0 -N rootfs_data -m
```

然后写入本 release 的 `ubi-kernel.bin` / `ubi-rootfs.bin`。

## 重要警告

- **不要照抄作者的 U-Boot env 偏移修改。** 自制 U-Boot 里的
  `board_env_offset += 4 * flash_block_size` 在 128 KiB 块下等于 `0x80000`，
  正好落在 `0:APPSBL` 起始（0x500000），`saveenv` 会覆盖 U-Boot 前 512 KiB，
  设备直接硬砖（作者这台就是这样坏的）。
- `0:ART`、`bdata` 是每台机器唯一的数据，不要覆盖或公开。
- 不要公开 `printenv` / `fw_printenv` 输出（含 Wi-Fi 密码、云 key、序列号）。
- 源码、补丁、完整说明见仓库 `README.md` 和 `ra80-openwrt/README.md`。
