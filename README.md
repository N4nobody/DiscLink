# 光盘通 DiscLink

在 Mac 上读写 Windows“类似于 USB 闪存驱动器”（Live File System）格式的光盘。

中文系统显示“光盘通”，其他语言的系统显示英文名 DiscLink，界面、错误提示和命令行输出也跟着切换中英文。

## 当前状态

| 盘型 | Windows 里的格式 | 本程序 |
|---|---|---|
| CD-RW、DVD-RW、DVD+RW、DVD-RAM、BD-RE | UDF 2.01 可备用分区 / 物理分区 | 读写：新增、覆盖、删除，删除后空间可回收 |
| CD-R、DVD-R、DVD+R（未封盘） | UDF 2.01 + VAT（虚拟分配表） | 读写：只能在末尾追加；覆盖是写一份新版本，删除只是从目录里去掉，空间不回收（Windows 也是这样） |
| UDF 2.50/2.60（元数据分区）、UDF 1.50 的 CD-R、BD-R | — | 只读 |
| 空白盘、已封盘的盘 | — | 不能写（空白盘请先在 Windows 上格式化） |

- ✅ 命令行工具 `udfdisc`：列目录、导出、写入（写完自动校验）、新建文件夹、删除、一致性检查
- ✅ 测试全部通过：14 项单元测试，加上 119 项端到端测试（用镜像文件模拟包写入，每包 16/32 块；模拟一次性写入盘，含 CD-R 每次写入后的 7 个链接块；结果用 macOS 自带的 UDF 驱动交叉验证）
- ✅ 真机测试（2026-10-19，LG GP78N 外置刻录机 + Windows 格式化的 DVD-R）：读取、追加文件和文件夹、删除都成功；Mac 写过的盘拿到 Windows 上能正常显示并继续追加，Windows 追加后再拿回 Mac 也能正常读写
- ⚠️ 还没在真机上测过：CD-RW / DVD±RW / BD-RE（包写入）、CD-R、DVD+R

### 真机测试中修过的问题

- 一次性写入盘上，光驱的“已刻录容量”在追加后不更新：改用轨道信息里的“最后刻录地址”找最新的 VAT。
- 读到未刻录的空隙时光驱会长时间重试：找 VAT 时逐个扇区读、限制失败次数；缓存读整组失败时改读单个扇区。
- Windows 只在 16 扇区一组（DVD 的 ECC 块）的最后一个扇区找 VAT：写 VAT 前先补空白扇区对齐。之前没对齐的盘可以用 `udfdisc fix-vat drive:1` 修复。
- ✅ 图形界面 App「光盘通 / DiscLink」：浏览、添加（按钮或拖进窗口）、新建文件夹、导出、删除、检查光盘、弹出光盘
- ✅ 界面适配 macOS 26 起的液态玻璃（Liquid Glass）：路径和状态是浮在文件列表上的玻璃胶囊，工具栏按功能分组；macOS 14–15 上自动退回原来的样式。需要 macOS 14 或更新
- ✅ App 图标：蓝底上一张完整的银色光盘，右下角压着一个液态玻璃互通徽章（透明玻璃环 + 蓝色圆 + 双向箭头）。用 Icon Composer 格式分层制作（`Resources/AppIcon.icon`），玻璃环完全透明并开启折射，会让下面的光盘边缘和刻纹发生弯曲（做法参考“地图”App 的图标）。macOS 26 起由系统渲染，并适配浅色、深色、着色、透明几种图标风格；macOS 14–15 用 actool 同时生成的普通图标。没装 Xcode 时，打包脚本退回用整张图（`Resources/AppIcon-1024.png`）

### 一次性写入盘是怎么写的

光盘上的东西不能改，所以每次操作：先把新文件的数据接在末尾写入，再把改过的目录、文件条目写在后面，最后写一张新的 VAT（“虚拟块号 → 实际位置”的映射表）。读盘时总是找最后一张 VAT，所以旧版本自然被新版本取代。中途出错时会把原来的 VAT 再写一遍，光盘回到操作前的状态，只是浪费了一点空间。

## 下载

在 GitHub 的 Releases 页面下载 `DiscLink.zip`，解压后把 `DiscLink.app` 拖进“应用程序”文件夹。需要 macOS 14 或更新。

App 没有经过 Apple 公证（只做了本机签名），第一次打开时 macOS 可能提示“无法验证开发者”：在 App 上点右键选“打开”，再在对话框里点“打开”即可。

## 编译

图形界面 App（生成 `build/DiscLink.app`，中文系统的访达里显示为“光盘通”，双击即可打开）：

```bash
scripts/build_app.sh
```

要用这个脚本打包，不要直接 `swift run UDFDiscApp`：只装命令行工具时，SwiftPM 会把 SDK 版本记成最低系统版本（14.0），macOS 就会按老程序的兼容模式显示，窗口外框不是液态玻璃。脚本在链接时写入了真实的 SDK 版本。

如果装了 Xcode 但还没同意它的许可协议，脚本会自动改用命令行工具（Command Line Tools）编译。

只编译命令行工具：

```bash
swift build
```

### App 用法

- 光驱里有盘时会自动载入：启动程序时已经有盘，或者程序开着时放进盘，都不用点左边。用“关闭光盘”关掉后不会再自动打开，换一张盘（或弹出再放回）才会。
- 也可以在左边栏手动选光驱，或者“打开镜像…”打开一个镜像文件（从命令行带镜像路径启动时，以镜像为准）。
- 注意：程序开着时会独占光驱，光盘不会出现在访达里；想在访达里用这张盘，就“关闭光盘”或退出程序。
- 打开光驱时程序会先让 macOS 推出光盘的卷宗，再独占光驱；关闭光盘或退出程序后还给 macOS，它会重新挂载。
- 添加：工具栏“＋”，或直接把文件、文件夹拖进文件列表。写完会自动读回来校验。
- 双击文件夹进入，顶部路径可以点回上级；右键有导出、删除。
- 文件列表和访达一样按类型显示图标，有“种类”一列；名字太长时悬停可看全名。
- 右上角标明盘的类型（例如“DVD-R · 一次性写入盘”），悬停可看这类盘能做什么。
- 底部：左边是能否写入（不能写时写明原因），中间是项目数或选中项目的大小，右边是容量条和剩余空间；“更多”菜单里有“检查光盘”。
- 第一次往真光盘写入时会提醒一次，建议先用不重要的光盘试。
- 弹出光盘：侧边栏光驱旁的 ⏏ 按钮、右键菜单、“文件 › 推出光盘”（⌘E）或“更多”菜单。光驱里没盘时 ⏏ 会打开托盘。
- “文件 › 关闭光盘”（⇧⌘W）只是把光驱还给 macOS，不弹出。

## 中英文

- 所有面向用户的文字都写成 `L("中文", "English")`（`UDFKit/Localization.swift`），两种语言放在一起，不需要 Xcode 的字符串目录。
- App 跟随 macOS 为它选定的语言（`en.lproj`、`zh-Hans.lproj`），所以和系统自带的菜单保持一致；命令行工具跟随用户的语言设置。
- 想临时切换：App 用 `open build/DiscLink.app --args -AppleLanguages "(en)"`；命令行用 `UDFDISC_LANG=en` 或 `UDFDISC_LANG=zh`。端到端测试固定用中文运行。

## 测试

```bash
scripts/test.sh
```

先跑单元测试（`swift run udfkit-tests`），再做端到端测试。临时文件放在系统临时文件夹，跑完自动删除；想保留就传一个文件夹路径：`scripts/test.sh ~/udf-test`。
单元测试做成了普通的可执行程序，因为 XCTest 和 Swift Testing 都需要完整安装 Xcode，只有命令行工具时用不了。

## 代码结构

| 文件 | 内容 |
|---|---|
| `Sources/CMMC/` | C 写的光驱接口：通过 IOKit 给光驱发 SCSI/MMC 命令 |
| `UDFKit/OpticalDrive.swift` | 光驱：识别盘型、设置写入参数、按包或追加写入 |
| `UDFKit/SectorDevice.swift` | 扇区设备（镜像文件和光驱共用的接口）、包写入缓存 |
| `UDFKit/Bytes.swift`、`Descriptors.swift` | 字节读写、CRC、描述符标签、文件名编码、时间戳 |
| `UDFKit/Structures.swift`、`SpaceBitmap.swift` | 文件条目、目录条目、空间位图 |
| `UDFKit/UDFVolume.swift` | 挂载：识别分区（物理 / 可备用 / 元数据 / VAT）、地址换算 |
| `UDFKit/UDFVolume+Read.swift` | 读取：目录、文件、路径、导出 |
| `UDFKit/UDFWrite.swift` | 写入可擦写盘：事务、空间分配、目录改写、删除 |
| `UDFKit/UDFWrite+VAT.swift` | 写入一次性写入盘：追加数据、写新的 VAT |
| `UDFKit/Check.swift` | 一致性检查、调试输出 |
| `Sources/udfdisc/` | 命令行工具 |
| `Sources/UDFDiscApp/` | 图形界面（SwiftUI）；`Glass.swift` 是液态玻璃效果和旧系统的退回样式 |
| `scripts/build_app.sh` | 打包成 .app（含图标） |
| `scripts/make_icon.swift`、`Resources/` | 绘制 App 图标：`flat` 画整张图，`layers` 画分层图标的四层：光盘、玻璃环、蓝色圆、箭头（写进 `AppIcon.icon/Assets`）；玻璃和折射参数在 `AppIcon.icon/icon.json` 里 |
| `Tests/UnitTests/` | 单元测试 |
| `scripts/test.sh` | 完整测试 |

## 用法

```bash
.build/debug/udfdisc drives
.build/debug/udfdisc info drive:1
.build/debug/udfdisc ls drive:1 /
.build/debug/udfdisc put drive:1 ~/Desktop/文件.pdf /文件.pdf
.build/debug/udfdisc check drive:1
.build/debug/udfdisc eject drive:1
```

目标也可以是镜像文件路径。打开光驱时会先卸载光盘，并独占光驱。
一次性写入盘的镜像要加 `--sequential`（只能在末尾追加），`--link 7` 模拟 CD-R 的链接块。

## 第一次上真光驱前

1. 先用一张**不重要的测试盘**（CD-R/DVD-R 写坏了就只能扔掉）。
2. 在 Windows 上把它格式化成“类似于 USB 闪存驱动器”，放几个文件。
3. 在 Mac 上依次运行 `info`、`ls`、`check`，确认能读，再试 `put`。
4. 写完拿回 Windows 确认能正常打开。

## 许可证

[MIT](LICENSE)
