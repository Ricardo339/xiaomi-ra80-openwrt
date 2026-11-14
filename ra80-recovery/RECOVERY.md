# RA80 硬件恢复说明

> **2026-11-14 事故（真实原因）：** 在自制 U-Boot 中执行 `saveenv` 后设备完全无输出。
> env 偏移补丁 `board_env_offset += 4 * sfi->flash_block_size` 假设块大小是 64 KiB；
> 但 MIBIB 记录的块大小是 **128 KiB**，4 块 = 0x80000，环境区实际写到
> `0x480000 + 0x80000 = 0x500000`，正好是 `0:APPSBL` 的起始地址。
> saveenv 擦除了 `0x500000~0x580000`，覆盖 U-Boot 镜像前 512 KiB（ELF 头），
> SBL1 无法加载，表现为无串口、无灯、无链路。
> **该版本 U-Boot 绝对不能再执行 saveenv。** APPSBLENV 只有 4 个 128 KiB 块，
> 并不存在补丁注释里说的“后半段 (0x4C0000)”；正确做法是去掉这行偏移。

## 现状

- 自制 32 位 U-Boot 已写入 `0:APPSBL`（mtd11），env 写入 `0:APPSBLENV`（mtd10）。
- 首次刷入后原厂系统可正常启动（已验证）。
- 之后写入一次性 `failsafe=1`，设备进入 U-Boot 网页路径后反复复位，
  网络（192.168.1.1 / 192.168.31.1）均无响应，链路周期性 Up/Down。
- 软件侧已无入口，需要 SPI-NAND 编程器。

## 芯片

- **Winbond W25N01GWZEIG**（SPI-NAND，1Gb = 128MB，WSON8 8×6mm，JEDEC `EF BA 21`）
  —— 已按实物丝印确认（背面，正面屏蔽罩下为主控/WiFi，不要动）
- uBootKit 的 `qpic_nand.c` 驱动表内含该型号（`0xef 0xba 0x21`），
  与第一次刷入后能正常读内核、启动原厂系统的事实一致。
- 需要支持 SPI-NAND 的编程器，例如 XGecu T48/T56、RT809H 等；
  普通 CH341A 对 SPI-NAND 支持有限，不建议。
- WSON8 8×6mm 需要对应测试座；无外露引脚，夹子不可靠，拆焊更稳。

## 恢复材料（不随仓库提供）

为了不公开分发厂商 bootloader 和本机唯一数据，**本仓库不包含任何分区备份**：

| 文件 | 用途 | 来源 |
|---|---|---|
| `mtd11-APPSBL.bin` | 原厂 U-Boot，写回 `0x500000` | 你自己机器的备份 |
| `mtd10-APPSBLENV.bin` | 原厂 U-Boot env，写回 `0x480000`（可选） | 你自己机器的备份（含 SN/MAC/云密钥，切勿公开） |
| `uboot-ra80-ours.bin` | 自制 U-Boot | 按 `uboot-port/` 自行编译（未随仓库提供） |
| `env-no-failsafe.bin` | 自制 U-Boot 的 env | 自行生成 |

md5 仅作校验参考（如果你本地还有这些文件）：

```
4ffcec2d43e9789d4adc40859a288bc5  mtd11-APPSBL.bin
71f76394adc4486539e8208cff553f51  mtd10-APPSBLENV.bin
19d68ec08686da091e92dfb53766e5dd  uboot-ra80-ours.bin
bf89158570611ae939fc6bbd7eaca4f2  env-no-failsafe.bin
```

恢复引导只需要原厂 `mtd11-APPSBL.bin`；`0:ART`/`bdata` 请使用自己机器的备份，
绝不要写入其他机器的校准数据。

## 分区偏移（来自 MIBIB，块=128KiB）

| 分区 | 偏移 | 大小 |
|---|---|---|
| 0:APPSBLENV | `0x480000` | `0x80000` (512 KiB) |
| 0:APPSBL | `0x500000` | `0x140000` (1.25 MiB) |
| 0:ART | `0x780000` | `0x100000` |
| rootfs (slot A) | `0xA80000` | `30 MiB` |
| rootfs_1 (slot B) | `0x2880000` | `30 MiB` |
| overlay | `0x4680000` | `57.5 MiB` |

芯片总容量 128 MiB（0x8000000）。

## 恢复步骤（原厂）

1. 拆下芯片或使用 WSON8 座/夹，**先整片读出 128MB 并备份**（重要）。
2. 将 `mtd11-APPSBL.bin` 写入芯片偏移 `0x500000`。
3. （可选）将 `mtd10-APPSBLENV.bin` 写入芯片偏移 `0x480000`。
   该文件含设备密钥，请使用自己机器的备份；不写也能启动——原厂 U-Boot
   在 env CRC 无效时会使用默认 env。
   （按页/块对齐；SPI-NAND 需由编程器处理片上 ECC）
4. 读回校验这两个区域。
5. 装回芯片，上电。原厂 U-Boot（`bootmiwifi`）+ 原厂 env 会从 slot A
   引导原厂系统（slot A 之前已用备份恢复为原厂）。

## 恢复后重试 OpenWrt 的正确顺序

第一次刷 U-Boot 后原厂系统能正常启动，说明 `bootipq` 路径是好的；
崩溃发生在 `failsafe` 网页路径。重试时：

1. 写 `uboot-ra80-ours.bin` → `0x500000`。
2. 写 `env-no-failsafe.bin` → `0x480000`（**绝不要再设 failsafe**）。
3. 上电，确认原厂系统启动（LAN 192.168.31.1，uptime 正常）。
4. 在同一个启动窗口内立即刷 OpenWrt：
   `mtd write /tmp/fw.ubi /dev/mtd18`（用 `/root/flash_openwrt.sh`）。
5. 重启后 `bootipq` 引导 arm64 OpenWrt，LAN 应为 `192.168.2.1`。

## 其它备注

- 如果编程器只能整片写，需要按 MIBIB 偏移把 21 个分区备份拼回整片镜像
  （本目录未提供整片镜像，因为现有备份是 MTD 数据区，不含 OOB）。
- 恢复后建议先只恢复原厂，确认设备可用，再考虑第二次尝试。
