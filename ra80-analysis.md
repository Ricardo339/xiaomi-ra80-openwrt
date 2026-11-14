# 小米 AX3000 (RA80 V2) OpenWrt 移植分析

> 生成日期：2026-11-11
> 目标设备：小米路由器 AX3000，型号 RA80 V2
> 目的：还原"付费闭源固件"的技术构成，并给出一条合法的自建路线
>
> 注：本文是早期分析稿。文中提到的原厂分区备份、原始 BDF、`device-tree.tar`
> 等文件**未随公开仓库提供**；相关命令仅作原理参考，操作请使用你自己机器的备份。

---

## 0. 一句话结论

付费固件没有发明任何东西。它就是：

```
高通 QSDK 4.4/5.4 内核
  + 闭源 WiFi 驱动 (qca_ol / umac / qdf)
  + 闭源 NSS 硬件加速 (qca_nss_drv / qca_nss_dp / qca_ssdk / ecm)
  + 原厂 BDF（板级校准文件）
  + 自编 OpenWrt 用户空间
  + 改过的 uboot
```

真正的门槛只有三样：**正确的 BDF、正确的板级 DTS、可回滚的刷机通道**。前两样的素材已经全部从本机提取出来。

---

## 1. 设备信息（实测）

| 项目 | 值 |
|---|---|
| 型号 | RA80 V2 |
| SoC | Qualcomm IPQ5018（2× Cortex-A53 @1.0GHz） |
| 设备树 model | `Qualcomm Technologies, Inc. IPQ5018/AP-MP03.3` |
| compatible | `qcom,ipq5018-mp03.3`, `qcom,ipq5018` |
| 内存 | 256MB（系统可见约 182MB） |
| 闪存 | 128MB SPI-NAND（QPIC NAND） |
| 2.4G | IPQ5018 片内 |
| 5G | QCN6122（外挂，PCIe） |
| 交换 | IPQ50xx 内置 ESS switch |
| 网口 | 1 WAN + 3 LAN，千兆 |
| 原厂固件 | 1.0.34 |
| 原厂内核 | Linux 4.4.60，armv7l（32 位），GCC 7.5.0 |
| 用户空间 | OpenWrt 18.06-SNAPSHOT，`ipq/ipq50xx`，`arm_cortex-a7` |
| SSH | 已开启，`root/root`（默认未改） |

---

## 2. 原厂固件的技术构成

### 2.1 内核模块（`lsmod` 实测）

WiFi（QCA 闭源栈）：

```
qca_ol       1317969   QCA 802.11ax 驱动
umac         2981193   MAC 层
qdf           118577   QDF 抽象层
wifi_3_0      697480
ath_pktlog     11510
```

NSS 硬件加速：

```
qca_nss_drv    829449
qca_nss_dp      36358
qca_ssdk       661948
ecm             674480
qca_mcs          43299
qca_nss_pppoe / qca_nss_pptp / qca_nss_l2tpv2 / qca_nss_gre / qca_nss_macsec
```

### 2.2 WiFi 固件版本

```
WLAN.HK.2.5.r4-00683-QCAHKSWPL_SILICONZ-1.94432.1.99251.5 v1
```

这是 QSDK 11.x 时代的固件。上游 `ath11k` 对 IPQ5018 使用的是 WLAN.HK.2.7 系列，两者不通用。

### 2.3 结论

原厂用户空间虽然是 OpenWrt 18.06，但**网络数据面和 WiFi 全部由高通闭源组件接管**。这解释了为什么：

- 原厂固件能跑满硬件加速（NSS），而官方 OpenWrt 的有线只有 300~500Mbps
- 付费固件能把 5G 点亮，而 crypt0nX 的免费移植 5G 无法发射

---

## 3. WiFi BDF 分析（核心）

### 3.1 BDF 文件

| 用途 | 文件 | 大小 |
|---|---|---|
| 2.4G（IPQ5018） | `/lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24` | 131072 |
| 2.4G 通用 | `/lib/firmware/IPQ5018/WIFI_FW/bdwlan.bin` | 131072 |
| 5G（QCN6122） | `/lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b60` | 131072 |
| 5G 通用 | `/lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.bin` | 131072 |
| NSS 固件 | `/lib/firmware/qca-nss0-retail.bin` | 761852 |

### 3.2 board id（关键）

原厂内核启动参数：

```
cnss2.bdf_integrated=0x24 cnss2.bdf_pci0=0x60 cnss2.bdf_pci1=0x60
cnss2.skip_radio_bmap=4
```

设备树中的对应属性：

| 节点 | 属性 | 值 |
|---|---|---|
| `soc/wifi@c000000`（2.4G） | `qcom,board_id` | **0x23 (35)** |
| `soc/wifi1@c000000`（5G） | `qcom,board_id` | **0x60 (96)** |

BDF 文件头偏移 `0x30`：

```
bdwlan.b24:  24 31 ...
bdwlan.b60:  60 5e ...
```

结论：

- 5G：board-id `0x60` 完全一致。
- 2.4G：DT 写 `0x23`，BDF 文件名和 cmdline 用 `0x24`，相差 1。**两个值都要注册。**

### 3.3 校准数据

`/lib/firmware/IPQ5018/caldata.bin` 是指向 `/tmp/IPQ5018/caldata.bin` 的软链接，运行时由 ART 分区（`mtd13`）生成。自建固件时需要用 `caldata_patch_data()` 把 ART 里的设备校准数据补进 BDF，否则可能出现功率异常、信号弱或无法发射。

ART 已完整备份：`ra80-backup/mtd13-ART.bin`（1MB）。

### 3.4 已生成的 `board-2.bin`

用 `ath11k-bdencoder` 把原厂 BDF 封装成开源驱动可加载的格式：

```
文件：tools/board-2-ra80.bin
大小：262776 字节
签名：QCA-ATH11K-BOARD
MD5 ：611319a9a412800d6d6ec9570df6f983
```

包含两个 board（各 131072 字节）：

| Board | 数据来源 | 注册的完整名字 |
|---|---|---|
| 2.4G | bdwlan.b24 | `bus=ahb,qmi-chip-id=0,qmi-board-id={35,36,255}[,variant=Xiaomi-RA80]` |
| 5G | bdwlan.b60 | `bus=pci,qmi-chip-id=0,qmi-board-id={96,255}[,variant=Xiaomi-RA80]` |

DTS 侧对应写法：

```dts
&wifi  { qcom,calibration-variant = "Xiaomi-RA80"; };
&wifi1 { qcom,calibration-variant = "Xiaomi-RA80"; };
```

> 注意：此文件由你自己设备的 BDF 生成，仅用于本机。不要公开分发，BDF 的再分发受高通授权限制。

---

## 4. NAND 分区表（实测）

128MB SPI-NAND，全部备份已完成并通过 MD5 校验。

| 偏移 | 大小 | 名称 | mtd |
|---|---|---|---|
| 0x000000 | 0x080000 | 0:SBL1 | mtd0 |
| 0x080000 | 0x080000 | 0:MIBIB | mtd1 |
| 0x100000 | 0x040000 | 0:BOOTCONFIG | mtd2 |
| 0x140000 | 0x040000 | 0:BOOTCONFIG1 | mtd3 |
| 0x180000 | 0x100000 | 0:QSEE | mtd4 |
| 0x280000 | 0x100000 | 0:QSEE_1 | mtd5 |
| 0x380000 | 0x040000 | 0:DEVCFG | mtd6 |
| 0x3C0000 | 0x040000 | 0:DEVCFG_1 | mtd7 |
| 0x400000 | 0x040000 | 0:CDT | mtd8 |
| 0x440000 | 0x040000 | 0:CDT_1 | mtd9 |
| 0x480000 | 0x080000 | 0:APPSBLENV | mtd10 |
| 0x500000 | 0x140000 | 0:APPSBL | mtd11 |
| 0x640000 | 0x140000 | 0:APPSBL_1 | mtd12 |
| 0x780000 | 0x100000 | 0:ART | mtd13 |
| 0x880000 | 0x080000 | 0:TRAINING | mtd14 |
| 0x900000 | 0x080000 | bdata | mtd15 |
| 0x980000 | 0x080000 | crash | mtd16 |
| 0xA00000 | 0x080000 | crash_syslog | mtd17 |
| 0xA80000 | 0x1E00000 | rootfs | mtd18 |
| 0x2880000 | 0x1E00000 | rootfs_1 | mtd19 |
| 0x4680000 | 0x3980000 | overlay | mtd20 |

当前启动槽位：`flag_boot_rootfs=0`，即 `rootfs`（mtd18）。
`uart_en=0`，串口默认关闭。
`bootdelay=5`。

---

## 5. 硬件引脚与网络（设备树实测）

### 5.1 LED（低电平点亮）

| 名称 | GPIO |
|---|---|
| sys_red | 24 |
| sys_blue | 25 |
| net_blue | 26 |
| net_red | 27 |

### 5.2 按键（低电平有效，带 60ms 消抖）

| 名称 | GPIO | linux,code |
|---|---|---|
| mesh | 28 | 0x109 (KEY_MESH) |
| reset | 38 | 0x198 (KEY_RESTART) |

### 5.3 网络

| 接口 | MAC | phy-mode | 说明 |
|---|---|---|---|
| dp1 | `xx:xx:xx:xx:xx:xx` | sgmii | 与路由器后台 MAC 一致 |
| dp2 | `xx:xx:xx:xx:xx:xx` | sgmii | 与 LAN 侧 ARP MAC 一致 |

- 交换芯片：`qcom,ess-switch-ipq50xx`
- 内部 PHY 地址：7（`mdio@88000` 的 `ethernet-phy@0`）
- 端口：port1（phy 7）、port2（forced 2500）

### 5.4 PCIe / WiFi

| 节点 | compatible | board_id |
|---|---|---|
| `wifi@c000000` | `qcom,ipq5018-wifi` | 0x23 |
| `wifi1@c000000` | `qcom,qcn6122-wifi` | 0x60 |
| `wifi2@c000000` | `qcom,qcn6122-wifi` | （未启用） |
| `wifi3/4@f00000` | `qcom,qcn9000` | （未启用） |

PCIe 控制器：`pci@80000000`（status ok）、`pci@a0000000`。

---

## 6. 已产出的文件

```
ra80-backup/                 21 个分区备份（md5 全部校验通过）
  mtd0-SBL1.bin ... mtd20-overlay.bin
ra80-firmware/               从 /lib/firmware 提取
  IPQ5018_WIFI_FW_bdwlan.bin
  IPQ5018_WIFI_FW_bdwlan.b24
  IPQ5018_WIFI_FW_qcn6122_bdwlan.bin
  IPQ5018_WIFI_FW_qcn6122_bdwlan.b60
  IPQ5018_WIFI_FW_fw_version.txt
  qca-nss0-retail.bin
  fingerprint.txt
device-tree.tar              原厂设备树完整归档
tools/
  ath11k-bdencoder           BDF 封装工具（开源）
  board-2-ra80.json          封装描述文件
  board-2-ra80.bin           成品：开源 ath11k 可加载的 BDF
  ipq5018-pz-l8.dts          最接近的官方参考 DTS
  ipq5018-qcn6122.dtsi       QCN6122 参考节点
  ipq-wifi-Makefile          板级固件安装规则
  ath11k-core.c              board 名字匹配逻辑
```

---

## 7. 距离"能跑的 OpenWrt"还差什么

### 7.1 板级 DTS

以 `ipq5018-pz-l8.dts` 为骨架，替换为本机数据：

- NAND 分区表（第 4 节）
- `&wifi` / `&wifi1` 的 `qcom,calibration-variant = "Xiaomi-RA80"`
- 两个 QCN6122 节点只启用 `wifi1`
- LED / 按键 GPIO（第 5.1、5.2 节）
- `dp1` / `dp2` 的 MAC 与 `phy-mode`
- ESS switch 端口映射与 PHY 地址
- 保留内存 / `qcom,bdf-addr` 等地址要与原厂一致

### 7.2 构建环境

- WSL2 或 Docker（Windows 上均可）
- 约 50GB 磁盘
- 参考树（任选）：
  - `qosmio/openwrt-ipq` 的 `25.12-nss` 分支
  - `mufeng05/openwrt-cmcc-pz-l8-nss`（IPQ5018 + QCN6122 + NSS，OpenWrt 25.12）
  - `kuncy7/openwrt-nss-edma`（内核 6.18，NSS 走上游 stmmac）

### 7.3 校准数据

把 `mtd13-ART.bin` 里的校准数据通过 `caldata_patch_data()` 补进 BDF，或确认原厂 BDF 已包含可用校准。

### 7.4 刷机与回滚

这是风险最高的一步。当前 `uart_en=0`，没有串口控制台。建议：

1. **保留 slot 1 原厂系统**，只把自建固件写到 slot 0，利用小米 uboot 的重试标志自动回退。
2. 先编 **initramfs** 版本，尽量不写 flash；但无 UART 时无法从 uboot 手动加载，只能通过 stock 系统的 kexec 或 ubiformat 测试。
3. 最稳妥的方案是做一个带 Web UI 的不死 uboot（付费固件卖的就是这个），但这本身是另一个工程。
4. 任何写操作前，确认 `ra80-backup/` 完整，并准备好小米官方修复工具作为网线级兜底。

---

## 8. 与付费固件的对应关系

| 付费固件的卖点 | 实际实现 |
|---|---|
| 5G 可用 | 原厂 `bdwlan.b60` + board_id 0x60，配 QSDK `qca_ol` 驱动 |
| 满血 NSS | QSDK 的 `qca_nss_*` + `ecm` 编译进固件 |
| 高功率 | 原厂 BDF 的功率表 + 国家码设置 |
| 刷机简单 | 带 Web UI 的不死 uboot + 一键脚本 |
| 可恢复原厂 | 原厂分区备份 + 官方修复工具流程 |

开源方案缺的不是"破解"，而是：

- 没人愿意为小存量设备维护 32 位旧内核 + 闭源驱动分支
- BDF 的板级差异需要逐台调试
- 没有商业激励

---

## 9. 边界与风险

- 本文所有素材均来自**用户本人持有的设备**，用于互操作与学习。
- `board-2-ra80.bin` 含高通 BDF 数据，**不要公开分发**。
- 不涉及破解付费固件的授权、加密或分发。
- 刷机有变砖风险。没有 UART 时，恢复手段依赖原厂 uboot 和官方修复工具；uboot 被写坏则只能拆机上编程器。
