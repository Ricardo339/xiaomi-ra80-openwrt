# RA80 V2 OpenWrt — 方案 A 逆向记录（2026-11-13 晚）

> 用途：数据保全 + 下次继续 A 的起点
> 设备状态：当前运行 OpenWrt initramfs（RAM），断电自动回原厂，原厂系统完好

---

## 0. 一句话结论

**交换机 CPU 链路和端口都通了，卡在 YT9215 内部 PHY ↔ 交换机 MAC 的数据总线。**
原厂驱动通过间接命令接口（`0xf0000` / `0xf0008` / `0xf000c`）初始化内部接口模式，主线 DSA 驱动没有实现这一层。

---

## 1. 实测证据链

| 测试 | 结果 | 结论 |
|---|---|---|
| 路由器发 10 个 ARP | 交换机 lan3 端口 MIB 发送计数精确 +9/+10 | SoC→交换机→端口 MAC 方向正常 |
| PC 收这些 ARP | 收到 0（`ReceivedBroadcastPackets` 不变，`ReceivedPacketErrors=0`） | PHY 没有把帧送上铜线 |
| PC 发 IPv6 ping / DHCP | 交换机 lan3 MIB 接收计数始终 0，`eth1` rx 始终 0 | PHY 没有把铜线帧交给交换机 MAC |
| PHY 链路状态 | 1Gbps、Link detected: yes、对端能力可读 | 铜线侧 PHY 是活的 |
| PHY BMCR 回环测试 | 一回环 link 就掉，帧发不出去 | 测试无法成立 |

## 2. 寄存器对照（原厂 vs 我们）

原厂值通过 `/proc/smi` 实时读取；我们的值通过驱动内 `DBG` 打印读取。

| 寄存器 | 地址 | 原厂 | 我们（已对齐后） | 说明 |
|---|---|---|---|---|
| EXT_CPU_PORT | 0x8000c | `0x8008` | `0x8008`（已改） | TAG_EN=1, PORT_EN=0, PORT=8 |
| CPU_TAG_TPID | 0x80010 | `0x9988` | `0x9988` | 一致 |
| SERDES_CTRL | 0x80028 | `0x1` | `0x1` | 一致 |
| IO_LEVEL | 0x80030 | `0x0` | `0x0` | 一致 |
| SERDES0 (port8) | 0x8008c | `0x27a` | `0x27a` | mode=2500BASE-X, speed 字段=2, pause 位 |
| SERDES1 (port9) | 0x80090 | `0x7a` | `0x7a` | SGMII 1000，未用 |
| CPU_COPY | 0x180690 | `0x4` | `0x1` | 原厂 FORCE_INT_PORT；我们 TO_EXT_CPU（DSA 设计不同） |
| ACT_UNK_UCAST/MCAST | 0x180734/8 | `0x0` | `0x165555`（诊断时 0x145555） | 原厂纯 VLAN 转发；我们 trap 到 CPU |
| FILTER_UNK_UCAST/MCAST | 0x180508/c | `0x400` | `0x7ff` | 设计不同 |
| port0-4 CTRL | 0x80100.. | `0x7fa` | `0x7fa` | **已对齐**（含 MAC AN + pause 位） |
| port8 CTRL | 0x80120 | `0x1fc` | `0x1fc` | **已对齐**（speed=4 即 2500） |
| port8 隔离 | 0x1802b4 | `0x0` | `0x7ff`（诊断时 0x0） | 原厂不做隔离 |
| port2 隔离 | 0x18029c | `0x0` | `0x6fc` | 原厂纯 VLAN |
| port2/8 LEARN | 0x1803d8/0x1803ec | `0x8000` / `0x0` | `0x20000` | 设计不同 |
| VLAN | — | 每口独立 VLAN，CPU 口 tagged（`'25t'` 等） | VLAN-unaware `0xc007ffc0` | **原厂用 VLAN 硬件转发，不用 CPU tag** |

原厂 swconfig 输出：
```
switch1: YT9215S, ports: 7 (cpu @ 5)
port 2 link up 1000      <- PC 所在口
port 4 link up 1000      <- SoC 内置 GE PHY（dp1）链路
port 5 link up 2500      <- CPU 链路（硬件 port 8）
VLAN 2: ports '25t'      <- 端口 2 untagged，CPU 口 tagged
```

## 3. 厂商模块逆向

文件：`ra80-recovery/yt_switch.ko`
- 来源：原厂 `/lib/modules/4.4.60/yt_switch.ko`
- 656,360 字节，ELF32 ARM，未剥离符号，md5 `881b667bb0d9cf4f36a5cc7207b628fc`
- 压缩包 md5：`312359d9325f25ef8d4eba040bc39e89`
- 动态获取方式：原厂系统 `gzip -9c` + `nc 192.168.31.135 9999 < /tmp/yt.ko.gz`，PC 端 Python 监听接收

反编译产物（Ghidra headless，脚本在 `ghidra-scripts/`）：
- `yt_switch_decomp.txt` — `fal_tiger_init`、`smi_switch_write/read`、`init_module`
- `yt_switch_decomp2.txt` — `yt_port_init`、`fal_tiger_port_mac_sync_phy`、`fal_tiger_port_mac_force_set`、`fal_tiger_port_extif_rgmii_delay_set`
- `yt_switch_decomp3.txt` — `/proc/smi` 接口、`smi_write_proc`、`smi_ctl_ioctl`
- `yt_switch_decomp4.txt` — `yt_nic_*` CPU 口/标签接口
- `yt_switch_decomp5.txt` — 表寄存器机制（`hal_table_reg_*`）
- `yt_switch_decomp6.txt` — 表访问底层
- `yt_switch_decomp7.txt` — **`int_yt861x_init`（PHY 初始化）**、`yt9215_intif_write`、`yt9215_extif_write`
- `yt_switch_asm.txt` — 关键函数汇编

### 3.1 厂商 PHY 驱动 `int_yt861x_init`

PFY 扩展寄存器访问方式：**写 PHY reg `0x1e` = 索引，再读写 reg `0x1f`**。

初始化序列（每个端口/PHY）：
```
若接口类型==1:
  ext[0x50] &= ~0x0C00
ext[0x408] &= ~0x0001
ext[0x29]  = (ext[0x29] & 0xffc0) | 0x08
ext[0x3a9] = (ext[0x3a9] & 0xffc0) | 0x17
green_enable_set(0)
```

我们实测 PHY2 当前值：
- ext 0x408 = 0x0001（写 0 不生效，疑似只读/自锁）
- ext 0x29  = 0x0010，写入 0x0008 后读回 0x0018
- ext 0x3a9 = 0x2f14，写入 0x2f17 成功
- ext 0x50  = 0x411a（本来就没有 0x0C00 位）

**实测照抄写入后，数据仍然不通。**

### 3.2 厂商内部接口配置 `yt9215_intif_write`

```
hal_mem32_read(dev, 0xf0008, &v)
v = (v & mask) | 4 | ((param3 & 0x1f) << 16) | ((param2 & 0x1f) << 21)
hal_mem32_write(dev, 0xf0008, v)
hal_mem32_write(dev, 0xf000c, param4)   /* 数据 */
hal_mem32_write(dev, 0xf0000, 1)        /* 触发 */
轮询 0xf0000 直到 0（最多 10 次）
```

- `param2` / `param3` 是 5 位端口/字段索引
- `param4` 是要写的值
- 这套接口 **mainline DSA 驱动完全没有实现**，是当前最大缺口

### 3.3 模块内其它有用符号

```
yt_nic_cpuport_mode_set / _get      CPU 口模式（模式 0/1，编码在 CPU_COPY 0x180690）
yt_nic_ext_cpuport_port_set/_get    外部 CPU 端口号
yt_nic_ext_cputag_en_set            外部 CPU 标签使能
yt_nic_cpuport_tagtpid_get          标签 TPID
int_yt861x_*                        PHY 驱动回调表（init/restart/autoNeg/...）
gpPhyDrvList -> int_yt861x_drv      内部 PHY 驱动注册
```

CPU_COPY 模式语义（从 `fal_tiger_nic_cpuport_mode_set` 推断）：
- mode 0 → 置 bit0（TO_EXT_CPU，外部 CPU 标签模式）
- mode 1 → 置 bit2（FORCE_INT_PORT，原厂正在用的值 0x4）

## 4. 当前构建树改动（未持久化为 patch，需备份）

以下改动直接改在 build_dir 的内核源码里（`linux-6.12.91/drivers/net/dsa/yt921x.c`），
**一旦 `make target/linux/clean` 就会丢失**。已完整备份到：
`ra80-recovery/yt921x-ra80-working.c`

改动清单：
1. 新增 `yt921x_debug_dump()`，在 `yt921x_chip_setup` 末尾和 `yt921x_phylink_mac_link_up` 里调用，打印关键寄存器
2. 端口控制字对齐原厂：内部口 `ctrl |= 0x7f8`，外部/CPU 口 `ctrl |= 0x1f8`
3. SerDes 2500 速度字段用 `2`（原厂值，主线是 4）
4. SerDes 强制打开 TX/RX pause 位
5. `EXT_CPU_PORT` 去掉 `PORT_EN`（与原厂一致 0x8008）
6. **诊断补丁（当前生效，需在正式版回退）**：
   - CPU 口隔离改为 0
   - CPU 口未知帧动作从 DROP 改为 FORWARD

其它已持久化在树里的改动：
- DTS：`ipq5018-ra80-v2.dts`（2500base-x、port8、port_mac_sel=QGMAC_PORT、LED 映射）
- `target/linux/qualcommax/config-6.12`：`CONFIG_NET_DSA_YT921X=y` 等
- `package/kernel/qca-nss-dp/patches/0001-nss_dp_main-tolerate-fixed-link-registration-failure.patch`
- `package/kernel/mac80211` 等非 NSS 配置

镜像：
- 当前测试镜像 `ra80-images/openwrt-...-initramfs-uImage.itb`
  md5 `5c0e46845d61ad822246ffd6eff109d5`（含诊断补丁 + mdio-tools + LED 修正）
- 上一版对齐镜像 md5 `03aac0dbf517c337f3e25eff073462f6`

## 5. 下一步（A 继续）

1. **定位 `yt9215_intif_write` 的调用点和参数**
   - Ghidra 脚本：列出 `yt9215_intif_write` 的 callers 并反编译
   - 目标：找出初始化时每个内部端口的 `param2/param3/param4`
2. **在 mainline 驱动里实现同样的间接写**
   - 通过 `yt921x_reg_write(priv, 0xf0008/0xf000c/0xf0000, ...)` 直接复刻（如果这些地址在主线驱动能访问）
   - 注意端口号映射：DSA port 0-3 ↔ 厂商 param2 的对应关系
3. **回退诊断补丁**，恢复 `PORT_EN`/隔离策略后再测
4. 如果间接接口仍不生效，采备用路线：
   - 用原厂 VLAN 方案（选项 B），或
   - 在 DSA 驱动里改用 `tag_8021q`（VLAN 标签）而非 CPU 私有标签

## 6. LED 结论（待下次编译）

原厂 DTB：
```
sys_blue  = GPIO24  默认 off
sys_red   = GPIO25  默认 on    <- 开机红灯
net_blue  = GPIO26
net_red   = GPIO27
全部高电平有效
```
物理位置（用户确认，从下往上）：GPIO25(红)、24(白)、27(红)、26(白)，
sys 组在下，net 组在上。

当前 DTS 已按此映射修正，但 LED 别名还要改：
```
led-boot      = &led_sys_red     /* 原为 blue，导致启动阶段白灯闪 */
led-failsafe  = &led_sys_red
led-running   = &led_sys_blue
led-upgrade   = &led_sys_red
```

## 7. 工具/环境备注

- WSL 里装了 `mdio-tools` 到 OpenWrt 镜像（`CONFIG_PACKAGE_mdio-tools=y` + `kmod-mdio-netlink=y`）
- mdio 语法：`mdio 90000.mdio-1:1d phy 2 raw 0x1e 0x29` / `raw 0x1f 0x0008/0xffff`
  - 内部 PHY 子总线：`90000.mdio-1:1d`
  - 用户态直接读交换机 SMI 寄存器不可靠（地址阶段会超时返回 0xdead），写可以
- 原厂 `/proc/smi`：`echo read 0xADDR > /proc/smi`，`echo write 0xADDR 0xVAL > /proc/smi`
- 原厂模块传输：`nc 192.168.31.135 9999 < file.gz`（原厂 nc 只有客户端模式）
- 刷机流程（每轮约 8~10 分钟）：
  原厂 `wget` → `mtd write /tmp/new.itb /dev/mtd19` → `reboot` →
  U-Boot 中断 → `nand read 0x44000000 0x2880000 0x01000000` → `bootm 0x44000000`

---

## 8. 续查记录（同日晚，继续 A）

### 8.1 原厂 0x80000-0x80100 全量快照（已补齐）

完整文件：`ra80-recovery/stock-80000-800fc.txt`、`ra80-recovery/stock-extra.txt`

关键发现：
- 该区间**只有部分地址可读**，其余返回 `0xdeadbeef`（地址未解码）：
  有效段 = `0x80000-0x80044`、`0x80080-0x80090`；`0x80048-0x8007c`、`0x80094-0x800fc` 全部 deadbeef。
- `0x80080 = 0xe902`、`0x80084 = 0x8c1f645a` 是**交换机自身 MAC 地址**（YT921X_MAC_ADDR_HI2/LO4），不是配置差异。
- `0x80088 = 0x73`、`0x80038 = 0x800001ff`、`0x80044 = 0x4c0a28`、`0x80040 = 0` 在驱动头文件里没有定义，属于未知寄存器，需要和我们的值比对。

### 8.2 原厂其它区间快照（PC 接 lan3）

```
0x80200..0x80220 端口状态: port0/1/3=e2, port2=1fa(PC), port4=1fa, port8=1fc
0x80388 CHIP_MODE = 2
0x80394 XMII_CTRL = 0
0x803a8/0x803ac = 0x1555b6db
0x80400/0x80408 (XMII0/1) = 0x04184108
0x60000 区 = 0xfadefade（本硬件无外部 MBus）
```

### 8.3 新增驱动内 debugfs 调试接口

在 build_dir 的 yt921x.c 里加了（脚本 `patch_yt_debugfs.py`）：

```
echo "r 0x80208"        > /sys/kernel/debug/yt921x/reg   # 读一个
echo "w 0x8002c 0x1fff" > /sys/kernel/debug/yt921x/reg   # 写一个
echo "d 0x80000 64"     > /sys/kernel/debug/yt921x/reg   # 连续读 64 个
```

结果打到内核日志（`DBGR ...` / `DBGW ...`），串口直接可见。
有了它以后**不用每次改驱动重新刷机**，可以实时试寄存器、实时看网络通不通。

### 8.4 编译环境坑

`make` 在 package/install 阶段报错：
```
find: The relative path 'Files/Git/ucrt64/bin' is included in the PATH ... insecure
```
原因：Windows 的 PATH 泄漏进了 WSL，GNU find 的 `-execdir` 拒绝执行。
解决：编译时用干净 PATH：
```
cd /root/openwrt-ipq-25.12-nss && \
env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin make -j16
```

### 8.5 下一轮实验计划（debugfs 就位后）

1. 在 OpenWrt 下 `d 0x80000 64`、`d 0x80200 9`、`d 0x80380 12`、`d 0x80400 4`，与原厂快照逐项 diff。
2. 对差异寄存器逐个用 `w` 写入原厂值，每写一个测一次 PC 是否能通（ARP/ping）。
3. 重点怀疑区：`0x803a8/0x803ac`（端口使能掩码）、`0x80388 CHIP_MODE`、`0x80038`、`0x80044`。
4. 若寄存器对齐后仍不通，回到厂商模块的 `int_yt861x_init`/PCS 表初始化（厂商 fal_tiger_init 里疑似有 0x301000/0x302000 段的大表写入，尚未解出）。

---

## 9. 关键进展（debugfs 就位后，2026-11-13 深夜）

### 9.1 镜像与调试
- debugfs 接口已修好（第一版有悬空指针 bug：延迟探测重试时 debugfs_create_dir 失败，
  file 里的 priv 指向已释放内存 → 一写就崩/看门狗重启）。修法：
  全局 `yt921x_dbg_priv`，只在 `yt921x_dsa_setup` 成功末尾赋值。
- 当前测试镜像 md5：`e73c43b7f74286439fd7824d16b96d7e`
- 用法：
  ```
  echo 'r 0x80208'        > /sys/kernel/debug/yt921x/reg
  echo 'd 0xc0900 16'     > /sys/kernel/debug/yt921x/reg
  echo 'w 0x80044 0x4c0a28' > /sys/kernel/debug/yt921x/reg
  ```
  结果在 dmesg（DBGR/DBGW 行）。

### 9.2 端口状态已与原厂完全一致
我们（PC 接 lan3 = 硬件 port2）：
```
0x80200..0x80220 = e2 e2 1fa e2 1fa e2 e2 e2 1fc   <- 和原厂逐个相同
0x80380 = ffc04030   0x80388 = 2   0x80394 = 0
0x80398 = 9dc0ff00   0x803a8 = 1555b6db   0x803ac = 1555b6db
```
结论：**交换机端口链路、外部 SerDes、PHY 全部正常，寄存器层面已对齐原厂。**

### 9.3 真正卡住的方向：SoC → 交换机
用 MIB（0xC0000 区，每端口 0x100）实测：

| 方向 | 证据 | 结果 |
|---|---|---|
| PC → 交换机 port2 | port2 RX_BROADCAST=0x30、RX_MULTICAST=0xd0、GOOD_BYTES≈30KB | ✅ 收到 |
| 交换机 → SoC | port8 TX_BROADCAST=0x30（与 port2 收到数一致） | ✅ 送到 CPU 口 |
| Linux 侧 | `lan3 rx_packets=256`（=48 广播 + 208 组播） | ✅ 到达内核 |
| SoC → 交换机 | ping 后 `eth1 tx_packets` +3，但 **port8 RX 计数始终 0**，port8 RX 错误计数也全 0 | ❌ 交换机完全没收到 |
| 交换机 → PC | port2 TX 全 0 | ❌ 因为 CPU 口没收到帧 |

也就是说：**反向（交换机→SoC）通的，正向（SoC→交换机）死。**
不是交换机的过滤/VLAN 问题（错误计数为 0），是 SoC 侧 UNIPHY 发送链路没有真正工作。

### 9.4 找到的第一个 SoC 侧配置差异
反编译原厂 `stock-mp03.3.dtb` 后对比：

| 项 | 原厂 | 我们 | 备注 |
|---|---|---|---|
| switch 节点 port@1 | 只有 forced-speed=2500 / forced-duplex=1 | 多了 `port_mac_sel="QGMAC_PORT"` | **关键差异** |
| dp2 phy-mode | `"sgmii"` | `"2500base-x"` | nss-dp 只存不用，可能无关 |
| dp2 fixed-link | 无 | 有（注册失败 -22，被补丁容忍） | 实际 phy_node 都是 NULL |
| clock 列表 | 一致 | 一致 | — |

SSDK 源码 `adpt_hppe_portctrl.c`：
```c
case PORT_WRAPPER_SGMII_PLUS:
    if (hsl_port_feature_get(dev_id, port_id, PHY_F_QGMAC))
        mac_type = PORT_GMAC_TYPE;
    else
        mac_type = PORT_XGMAC_TYPE;
```
`port_mac_sel="QGMAC_PORT"` 会让我们走 **PORT_GMAC_TYPE**，
而原厂没写这个属性 → 走 **PORT_XGMAC_TYPE**。
怀疑这就是 SGMII+ 2500 发送不通的原因（收发方向配置不对称）。

### 9.5 已做的实验
- 写 `0x80044 = 0x4c0a28`：读回 0x000a0000；写 0x400000 读回 0，**不是普通配置寄存器**（疑似状态/命令），不可改。
- `0x8002c`、`0x80028`、`0x80038`、`0x803a8/ac` 等均已与原厂一致。

### 9.6 下一步
1. 已删掉 DTS 里的 `port_mac_sel`（仓库和构建树都改了），重编刷机验证
   —— 这版镜像重建完成后先测 ping。
2. 如果仍不通，改 `dp2` 的 phy-mode 为 `"sgmii"`、去掉 fixed-link（完全照抄原厂）。
3. 再把 `switch` 节点的 resets/clocks 与原厂完全对齐（当前少了 ge_phy 两个复位）。

---

## 10. 重要教训：build_dir 里的内核改动会被冲掉！

### 10.1 发生了什么
改完 `target/linux/qualcommax/files/.../ipq5018-ra80-v2.dts` 后重新 `make`，
OpenWrt 重新解压/打补丁了内核源码，**build_dir 里的 yt921x.c 被还原成原始版**：
debugfs、DBG 打印、SerDes 对齐等全部消失。
刷机测试的镜像 `572c502a0d2654bf6df254724f6505f7` 实际上是个"原版驱动"，
所以 ping 仍然不通，这次实验作废。

### 10.2 永久解决办法（已做）
把 build_dir 的改动**生成为正式内核补丁**放进构建树：
```
target/linux/qualcommax/patches-6.12/800-net-dsa-yt921x-ra80.patch
```
内容 = 原始 799 补丁之后的全部改动（debugfs / DBG 打印 / SerDes / EXT_CPU_PORT /
端口对齐 / 诊断 / core 写）。仓库副本也在：
`ra80-openwrt/target/linux/qualcommax/patches-6.12/800-net-dsa-yt921x-ra80.patch`

以后再改驱动：直接改这个 patch（或改完后重新生成 diff），不要只改 build_dir。

### 10.3 DTS 侧当前实验
已按原厂 DTB 删除 `port_mac_sel = "QGMAC_PORT"`（原厂没有这个属性，
SSDK 会选 PORT_XGMAC_TYPE 而不是 PORT_GMAC_TYPE）。
正在重新编译含"全部驱动改动 + 无 port_mac_sel"的镜像。

### 10.4 待验证清单（按顺序）
1. 新镜像（全补丁 + 无 port_mac_sel）：ping 是否通？
2. 若不通：把 dp2 的 `phy-mode` 改成 `"sgmii"`、删掉 fixed-link（完全照抄原厂）。
3. 若还不通：对比原厂 switch 节点 resets（我们少 ge_phy_bcr_rst / ge_phy_misc_rst）。
4. 用 debugfs 读 UNIPHY/SSDK 侧状态（0x98000 区需要 ioremap，暂未实现）。

---

## 11. 找到根因：REVSGMII（关键突破）

社区线索（OpenWrt 论坛 241325、zcop/immortalwrt 提交 e24681d、David Yang 本人）：

> "YT9215s + IPQ5018 works on 2500Base-X mode in an old unofficial port,
> **it stops working in the latest version, probably due to unknown changes in qca-ssdk**.
> REVSGMII (SGMII in PHY role) is the only available mode for the (mainline) OpenWRT ...
> we abuse SGMII to denote REVSGMII."

### 为什么这解释了"单向不通"
我们现在这版 qca-ssdk（2025.05.30）里，`port_mac_sel = "QGMAC_PORT"` 会让 SoC 的
UNIPHY 以 **SGMII PHY（QGMAC）角色** 工作。如果交换机 CPU 口还按老办法配成
**2500BASE-X（MAC 角色）**，两端角色反了：
- 交换机 → SoC 方向能收（SoC 的 PHY 角色能收 MAC 发来的时钟/数据）
- SoC → 交换机方向死（交换机作为 MAC 等不到 PHY 的时钟）
这和我们实测完全吻合（port8 RX 永远 0，port8 TX 正常）。

### 已实施的修改
1. 驱动 `yt921x_port_config()`：
   ```c
   case PHY_INTERFACE_MODE_SGMII:
       /* abuse SGMII for REVSGMII */
       ctrl = YT921X_SERDES_MODE_REVSGMII;
   ```
   补丁脚本 `patch_yt_revsgmii.py`，已合入 `800-net-dsa-yt921x-ra80.patch`。
2. DTS：
   - `port@1` 恢复 `port_mac_sel = "QGMAC_PORT"`（SGMII+ 必需）
   - `ethernet-port@8`：`phy-mode = "sgmii"`，fixed-link 加 `pause; asym-pause;`
3. 预期交换机 SERDES0[0x8008c] 的 mode 字段从 4（2500BASEX）变成 1（REVSGMII）。

### 参考配置（社区原话）
```
port@1 { port_id=<2>; port_mac_sel="QGMAC_PORT"; forced-speed=<2500>; forced-duplex=<1>; };
port@8 { reg=<8>; phy-mode="sgmii"; ethernet=<&dp2>;
         fixed-link { speed=<2500>; full-duplex; pause; asym-pause; }; };
```
注意：`sgmii` 模式下 phylink 会打印 "fixed link full duplex 2500Mbps not recognised"，
但仍会以 2.5Gbps 起来，属于正常现象。

---

## 12. REVSGMII 生效：双向流量出现了（但有新问题）

镜像 `7f323d042029fa78fd470ba7dd41594c`（REVSGMII + 诊断补丁未回退）启动日志：

```
[5.19] DBG SERDES0[8008c]=0000007a   (复位默认 SGMII)
[5.79] DBG SERDES0[8008c]=000000fa   (mode=1 REVSGMII，补丁生效)
[7.64] net eth1: Unexpected EtherType 0x0806   <- ARP
[7.83] net eth1: Unexpected EtherType 0x0800   <- IPv4
```

**结论：SoC ↔ 交换机 双向都能过帧了。** REVSGMII 就是根因。

但随即内核 panic：
```
kernel BUG at mm/slub.c:547
__slab_free -> kfree -> skb_free_head -> ... -> dsa_switch_rcv
```
原因：交换机把**未打标签（untagged）**的普通帧发到了 CPU 口，
`tag_yt921x.c` 的 `yt921x_tag_rcv()` 发现 EtherType 不是 0x9988，
走 `kfree_skb(); return NULL;` 路径，在 nss-dp 的 skb 上触发了 slab 崩溃。

为什么会发 untagged 帧：之前为排查加的**诊断补丁**：
- CPU 口 isolation = 0（允许所有出方向）
- CPU 口 unknown 动作 = FORWARD（原本是 DROP）

这让用户口的广播/未知帧被当作普通转发发到 CPU 口（不带 tag）。

### 已回退诊断补丁
`patch_yt_diag_revert.py`：恢复主线行为
```c
/* CPU 口 isolation */
ctrl = ~(u32)0;

/* CPU 口 unknown 动作 */
ctrl &= ~YT921X_ACT_UNK_ACTn_M(port);
ctrl |= YT921X_ACT_UNK_ACTn_DROP(port);
```
正在编译新镜像（REVSGMII + 主线转发策略）。

---

## 13. Panic 根因：tag 驱动双重释放（DSA 核心也会 free）

`net/dsa/tag.c: dsa_switch_rcv()`：
```c
nskb = cpu_dp->rcv(skb, dev);
if (!nskb) {
        kfree_skb(skb);   /* 核心负责释放 */
        return 0;
}
```
而 `net/dsa/tag_yt921x.c` 的 4 个错误分支都写成：
```c
kfree_skb(skb);
return NULL;
```
→ skb 被释放两次 → `kernel BUG at mm/slub.c:547`（__slab_free）。

对照主线其它 tag 驱动（如 `tag_ksz.c`）都是只 `return NULL`，不自己 free。

### 修复
新建补丁 `801-net-dsa-tag-yt921x-fix-double-free.patch`（仓库同路径也有备份），
把 4 处 `kfree_skb(skb); return NULL;` 改成只 `return NULL;`。

注意：这不是 nss-dp 的问题，是 **tag_yt921x 驱动与 6.12 DSA 核心的接口约定不匹配**。
（估计 zcop/immortalwrt 用的 v6.19 backport 里已经修了。）

正在编译验证。

---

## 14. 又一个关键：EXT_CPU_PORT 的 PORT_EN 位必须置 1

头文件定义：`PORT_EN = BIT(14) = 0x4000`（不是 0x2000！）
主线原始代码：`TAG_EN | PORT_EN | PORT(8)` = **0xc008**。

之前"对齐原厂"的补丁把 PORT_EN 去掉了（原厂 0x8008），
导致交换机的 **CPU tag 引擎不工作**：
- 我们发的带 tag 帧到了交换机（port8 RX +3），但交换机没按 tag 转发 → port2 TX = 0
- 用户口→CPU 的帧也全是 untagged 洪水

### 实测
在运行中的系统里用 debugfs 写入：
```
w 0x8000c 0xc008   -> 读回 0xc008（成功）
```
然后 ping PC：
```
port2 TX_BROADCAST = 3   <- 我们的 ARP 请求真的从 lan3 发出去了！
```
（之前一直是 0。）

**结论：PORT_EN 必须保留主线的写法，不要"对齐原厂"。**

### 本轮改动（构建中）
从原始 799 驱动重新构建最小补丁集，只保留：
1. REVSGMII hack（SGMII → REVSGMII）
2. debugfs 调试接口
3. DBG 寄存器打印

**删除**了此前所有"对齐原厂"的改动：
- port CTRL 的 0x7f8/0x1f8
- SerDes speed 2 / 强制 pause
- EXT_CPU_PORT 去 PORT_EN
- 0x8002c/0x80044 core 写
- 诊断补丁

DTS 保持：`port_mac_sel="QGMAC_PORT"` + `ethernet-port@8 phy-mode="sgmii"` +
fixed-link 2500（pause/asym-pause）。

---

## 15. ✅ 数据通路打通！（2026-11-14 凌晨）

### 15.1 实测结果
路由器 ping PC 的 IPv6 链路本地地址：
```
ping -6 -c 4 -W 2 -I br-lan fe80::1a78:1dd6:729e:b5
64 bytes from fe80::1a78:1dd6:729e:b5: seq=0 ttl=64 time=4.750 ms
64 bytes from fe80::1a78:1dd6:729e:b5: seq=1 ttl=64 time=0.643 ms
64 bytes from fe80::1a78:1dd6:729e:b5: seq=2 ttl=64 time=0.648 ms
64 bytes from fe80::1a78:1dd6:729e:b5: seq=3 ttl=64 time=0.569 ms
4 packets transmitted, 4 packets received, 0% packet loss
```
**双向收发正常，交换机驱动通了！**

### 15.2 三个必要条件（缺一不可）
| # | 条件 | 说明 |
|---|---|---|
| 1 | `SERDES0` mode=1 (REVSGMII) | 驱动 SGMII → REVSGMII |
| 2 | `SERDES0` speed 字段=2（即 0xfa） | 主线写 4（0xfc）不通，实测必须 2 |
| 3 | `EXT_CPU_PORT`=0xc008 | TAG_EN(bit15) + **PORT_EN(bit14=0x4000)** + PORT(8) |

实测验证：
- 写 0xfc → ping6 100% 失败
- 写 0xfa → ping6 4/4 成功

### 15.3 ⚠️ 测试方法踩的坑（重要）
PC 的以太网口（连 RA80）**已经掉到 169.254.x 的 APIPA 地址**，
原来的 192.168.31.135 是原厂 DHCP 给的，租约过期后没了。
所以所有 `ping 192.168.31.135` 的测试都是无效的：
- Windows 把 192.168.31.1 的流量走了另一张网卡（以太网 2，10.67.206.x）
- 路由器发的 ARP 请求 PC 也不会回应（那不是它的 IP）

**正确测试方法**：用 IPv6 链路本地地址
```
# PC 上查：netsh interface ipv6 show addresses "以太网"
# 路由器上：
ping -6 -c 4 -I br-lan fe80::xxxx
```

### 15.4 最终补丁清单（都在仓库 ra80-openwrt/ 下有备份）
1. `800-net-dsa-yt921x-ra80.patch`
   - REVSGMII hack
   - SERDES 2500 → speed 字段 2
   - debugfs 调试接口 + DBG 打印（可选，保留方便以后调试）
2. `801-net-dsa-tag-yt921x-fix-double-free.patch`（tag 驱动双重释放）
3. DTS：`port_mac_sel="QGMAC_PORT"`、`ethernet-port@8 phy-mode="sgmii"`、
   fixed-link 2500 + pause/asym-pause
4. qca-nss-dp fixed-link 容错补丁（更早就有）

### 15.5 后续
- 刷入持久化 speed-2 的镜像，确认冷启动直接可用（不再靠 debugfs 手写）
- IPv4 测试：给 PC 网卡设静态 192.168.31.135 或配置 OpenWrt DHCP
- LAN1/LAN2/WAN 逐个端口验证
- LED 修正（red 启动闪烁）与正式 DTS/固件整理

---

## 16. 最终验证结果（2026-11-14）

### 冷启动镜像
`ra80-images/openwrt-qualcommax-ipq50xx-xiaomi_ra80-v2-initramfs-uImage.itb`
md5 **94b5f85adac0373ed96273e7187193ac**

启动即生效（不需要任何 debugfs 手写）：
```
EXT_CPU_PORT[8000c]=0000c008
SERDES0[8008c]=000000fa
```

### 实测（冷启动后直接测）
| 测试 | 结果 |
|---|---|
| 路由器 ping PC IPv6 链路本地 | **3/3 通，0% 丢包** |
| PC 从 OpenWrt 获取 DHCP | 192.168.2.230 / 网关 192.168.2.1 |
| PC ping 路由器 IPv4 | **3/3 通，0% 丢包** |

### 最终配置总结（就是这几条让网通了）
**驱动**（`800-net-dsa-yt921x-ra80.patch`）：
1. `PHY_INTERFACE_MODE_SGMII` → `YT921X_SERDES_MODE_REVSGMII`
2. `SPEED_2500` 的 SerDes speed 字段写 **2**（不是 4）
3. 保留主线 `EXT_CPU_PORT = TAG_EN|PORT_EN|PORT(8)`（0xc008）
4. debugfs（`/sys/kernel/debug/yt921x/reg`）+ DBG 打印（调试用，可留）

**tag 驱动**（`801-net-dsa-tag-yt921x-fix-double-free.patch`）：
- 4 处 `kfree_skb(skb); return NULL;` 去掉 free，避免和 DSA 核心双重释放

**DTS**：
```dts
port@1 {
    port_id = <2>;
    port_mac_sel = "QGMAC_PORT";
    forced-speed = <2500>;
    forced-duplex = <1>;
};
ethernet-port@8 {
    reg = <8>;
    phy-mode = "sgmii";
    ethernet = <&dp2>;
    fixed-link { speed = <2500>; full-duplex; pause; asym-pause; };
};
```
LED 别名已改：`led-boot = &led_sys_red`（启动阶段闪红灯）。

### 待办
- [ ] 目测 LED 启动行为（红灯闪 → 启动完成只亮白灯）
- [ ] 换线测试 lan1 / lan2 / wan
- [ ] 决定是否去掉 DBG 打印做正式版
- [ ] 把 patch 提交到自己的 OpenWrt 分支

---

## 17. LuCI（Web UI）补充

之前的镜像是最小配置（`.config` 里根本没有 `CONFIG_PACKAGE_luci`），
所以 80 端口没人监听，Web 管理页面不存在。

### 已做
```
CONFIG_PACKAGE_luci=y
make defconfig && make -j16
```
新镜像 md5 **40550e0cadac0...（完整值 40550e0c35f392cb5977b07060d79129）**，
刷入后验证：
- `uhttpd` 正在运行，监听 0.0.0.0:80
- `http://192.168.2.1` 正常跳转 LuCI
- 空密码 root 登录成功，`/cgi-bin/luci/admin/status/overview` 返回 200

### 注意
- 路由器总内存只有 168MB（可用约 19MB），在路由器上 `apk update` 会 OOM 被 kill，
  **装软件要在编译端加包，不要在设备上临时装**。
- 默认 root 无密码，局域网内谁都能进 LuCI，建议尽快 `passwd` 设密码。

---

## 18. net 灯逻辑（之前确实做漏了）

之前只定义了 LED 节点，没有写任何驱动逻辑，所以 net 灯两个都是灭的。
sysfs 名称：`blue:wan` / `red:wan`（DTS 里 function=WAN 自动生成）。

### 实现
1. DTS：`led_net_red` 的 `default-state` 改成 `"on"`
   （开机 WAN 没连时先亮红灯）
2. 新 hotplug 脚本：
   `target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/iface/30-net-led`
   ```sh
   [ "$INTERFACE" = "wan" ] || exit 0
   ifup)          red=0 blue=1   # WAN 通 -> 白灯
   ifdown/failed) red=1 blue=0   # WAN 断 -> 红灯
   ```
3. trigger 是 `[none]`，直接写 brightness 不会被覆盖。

### 行为
- 开机无 WAN：net 红灯常亮
- WAN 插上并 ifup：红灯灭、白灯亮
- WAN 断开：白灯灭、红灯亮

### 18.1 验证（镜像 897447d275a061ab36b1ed9c25ff7d46）
- WAN 未插线（operstate=down）时：`red:wan=1`，`blue:wan=0` ✅ 红灯常亮
- hotplug 脚本已进镜像：`/etc/hotplug.d/iface/30-net-led`
- uhttpd 监听 80，LuCI 正常
- PC 从 OpenWrt 拿到 DHCP 192.168.2.230，网关 192.168.2.1
- ping 192.168.2.1 2/2 通

注意：中途串口杜邦线松过一次（COM3 能打开但 0 字节），插紧后恢复正常。

---

## 19. 阶段 1：OpenWrt 装进 NAND（mtd19），5G 修复成功

### 19.1 安装方式（不占用 RAM）
sysupgrade.bin 是 tar（kernel 4.37MB + root 12.36MB），直接在 PC 上拆开，
用 HTTP 流式写入 UBI 卷（`ubiupdatevol -s <size> -` 支持 stdin）：
```
ubidetach -m 18          # 释放原厂 UBI
ubiformat /dev/mtd19 -y
ubiattach -m 19 -d 0
ubimkvol /dev/ubi0 -N kernel -s 4372252
ubimkvol /dev/ubi0 -N rootfs -s 12362752
ubimkvol /dev/ubi0 -N rootfs_data -m
wget -qO- http://PC:8000/ra80-kernel | ubiupdatevol /dev/ubi0_0 -s 4372252 -
wget -qO- http://PC:8000/ra80-root   | ubiupdatevol /dev/ubi0_1 -s 12362752 -
```
卷布局：kernel 35 LEB、rootfs 98 LEB、rootfs_data 83 LEB（约 10.5MB）。

### 19.2 U-Boot 引导命令（每次手动）
```
setenv mtdids nand0=nand0
setenv mtdparts 'mtdparts=nand0:0x2880000@0(pre),0x1E00000@0x2880000(rootfs_1),0x3980000@0x4680000(overlay)'
ubi part rootfs_1
ubi read 0x44000000 kernel
setenv bootargs 'ubi.mtd=rootfs_1 rootfstype=squashfs cnss2.bdf_integrated=0x24 cnss2.bdf_pci0=0x60 cnss2.bdf_pci1=0x60 cnss2.skip_radio_bmap=4 rootwait uart_en=1 swiotlb=1'
bootm 0x44000000
```
注意：`mtdparts` 变量必须以 `mtdparts=` 开头，否则 U-Boot 报
"mtdparts variable doesn't start with 'mtdparts='"。

### 19.3 结果
- 根文件系统：`overlayfs:/overlay`，`/overlay` 是 ubi0_2（ubifs，7.4MB 可用 6.9MB）
- MemAvailable 从 2.5MB 提升到 **28MB**（initramfs 的 43MB tmpfs 被释放）

### 19.4 5G 根因与修复
ath11k 报：
```
page allocation failure: order:8, mode:0xcc1(GFP_KERNEL|GFP_DMA)
ath11k_dp_link_desc_setup ← mon_attach
```
不是"总内存不够"，是 **DMA 区无法分配 1MB 连续内存**：
monitor desc 环 4096 项 × 128B + 128 = 524416 字节，刚好超过 order-7（512KB），
只能申请 order-8（1MB），DMA 区最大只有 512KB 块 → 失败。

补丁 `949-wifi-ath11k-reduce-ring-sizes-for-lowmem.patch`：
- DP_RXDMA_MONITOR_DESC_RING_SIZE 4096 → **1024**（分配降到 order-6，256KB）
- 同时按 CR881x 方案缩小：TX_COMP 32768→4096、RXDMA_BUF 4096→1024、
  MON_STATUS 1024→512、MONITOR_BUF 4096→1288、MONITOR_DST 2048→128。
补丁在 `ra80-openwrt/package/kernel/mac80211/patches/ath11k/`。

### 19.5 验证
```
/sys/class/ieee80211/ -> phy0 phy1        # 两个射频都在
phy0-ap0  2.4G  ch1   20MHz  SSID OpenWrt
phy1-ap0  5G    ch36  80MHz  SSID OpenWrt
```
默认 wireless 配置里两个 iface 是 disabled=1，已改为 0 并 `wifi reload`。
LuCI 200，LAN DHCP/IPv4/IPv6 正常，net 红灯逻辑正常（WAN 未插=红）。

### 19.6 现状与下一步
- 原厂 mtd18 仍然完好；断电默认进原厂
- 目前进 OpenWrt 需要串口在 U-Boot 手动执行 19.2 的 6 条命令
- 下一步（阶段 2）：把 mtd18/19/20 合并成约 117MB 单系统 + U-Boot 自动引导
