# MinReader — 本地阅读器

纯 Objective-C，无第三方依赖。云端编译未签名 IPA，自己用全能签/ESign 签名安装。

## 下载

**方式一（推荐，不依赖 GitHub 网页）**：直接点对话里的文件链接
**方式二**：`https://github.com/lichuntu/minreader/releases/download/v1.3/MinReader.ipa`

## v1.3 更新

- **EPUB 读取外部 CSS**：EPUB 的样式大多写在独立 `.css` 文件里（`<link>` 引用），
  之前的版本完全没读 → 彩色文字/特殊字号全部丢失。现在会收集并解析 CSS。
  支持：颜色（`#rgb` / `#rrggbb` / `rgb()` / `rgba()` / 具名色）、`font-weight`、
  `font-style`、`text-decoration`、`font-size`（% / em / rem / larger / smaller）。
  优先级：内联 `style` > `class` > 标签规则 > 标签语义。
  **颜色可读性保护**：CSS 里的颜色如果和背景亮度太接近（比如黑底黑字），
  会自动往反方向调整，保证看得见。
- **目录大幅增强**：书名、作者、总章数、阅读进度百分比、每章字数、当前章高亮并标记「正在阅读」
- **底栏改为「目录 + 设置」**，去掉右上角目录按钮
- **TXT 章节名改进**：兼容「第1章」与章节名分成两行的情况（如「第1章」+「喝酒不开车」）

## 支持格式

| 格式 | 说明 |
|---|---|
| **TXT** | 编码自动嗅探：BOM → UTF-8 → **GB18030(GBK/GB2312)** → Big5 → Latin1 兜底。中文老 txt 不乱码 |
| **EPUB** | 自研 ZIP 解析器（zlib raw inflate），按 `container.xml → .opf → spine` 顺序提取章节 |
| **Markdown** | 按纯文本阅读 |

## 阅读功能

- **分页翻页**（不是滚动）
  - 点屏幕**左侧 28%** 上一页，**右侧 28%** 下一页，**中间** 呼出/隐藏工具栏
  - 左右滑动翻页
  - 翻页动画：**仿真翻页 / 平滑滑动 / 无动画**
- **背景色**：8 种纯色（白 / 米黄 / 护眼绿 / 浅灰 / 暖粉 / 深灰 / 夜蓝 / 黑），正文颜色按背景明暗自动切换
- **亮度**：滑杆调节（退出 App 恢复系统亮度）
- **字号**：12–40，重排后自动保持当前阅读位置
- **目录**：按章跳转
- **进度**：记住读到第几章第几页，书架上也显示

## 书架

- 右上角 `+` 从「文件」里选文件导入（可多选，重名自动加序号）
- 在「文件」App 里可以直接把书拖进 `阅读器` 文件夹（`UIFileSharingEnabled`）
- 其他 App 里「分享 → 用阅读器打开」也能送进来
- 左滑删除

## 实现要点

**分页**：TextKit1 的 `NSLayoutManager` + 每页一个 `NSTextContainer`，共享同一个 `NSTextStorage`。
同一套排版对象既用来切页、也用来绘制（`drawGlyphsForGlyphRange:atPoint:`），
所以分页结果和渲染结果**必然一致**，不会出现串页或漏字。

**章与章之间**：每章独立排版并缓存（最多留 3 章），翻到章尾时预热相邻章，避免卡顿。

**EPUB 解压**：iOS 没有公开的 zip API，`src/MTZip.m` 自己解析中央目录 + 用系统 zlib 做 raw inflate。

## 编译

```bash
bash build.sh      # macOS 上跑，产物 dist/MinReader.ipa
```

push 到 GitHub 则由 Actions 自动编译（macOS runner，Xcode 26.3 / iPhoneOS 26.2 SDK）。

**手工编译的链接参数**（Xcode 不会帮你自动加，容易踩坑）：

```
-framework UIKit -framework Foundation -framework CoreGraphics
-framework CoreText -framework UniformTypeIdentifiers -lz
```

## 目录结构

```
src/main.m            程序入口
src/AppDelegate.m     窗口、外部文件打开
src/MTBookshelfVC.m   书架：列表 / 导入 / 删除
src/MTReaderVC.m      阅读器：分页、翻页、配色、设置面板
src/MTBook.m          书籍解析：编码嗅探、HTML 转文本、章节切分
src/MTZip.m           自研 ZIP 读取器
resources/Info.plist  文档类型声明、文件共享
```

## 已知限制

- EPUB 只取文字，**图片和复杂排版会丢失**
- 分页按「章」进行，超长章节（>10 万字）首次打开会有一瞬间的排版耗时
- 亮度是改系统亮度，退出 App 会恢复
