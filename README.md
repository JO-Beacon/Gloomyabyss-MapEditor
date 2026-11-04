# Gloomyabyss 地图编辑器

编辑 [Gloomyabyss](https://github.com/Gloomy-Ym/Gloomyabyss) 的世界数据：地形、道具、对象、传送门和段。

## 能做什么

- 新建世界，自定义尺寸
- 打开单个 `.gmap` 世界包，或直接打开游戏的世界目录
- 地形绘制：调色板选地形，点/拖刷格子
- 道具：从 `props.json` 选类型，点格子放置或删除
- 对象：从 `objects.json` 选类型，点格子放置或删除
- 传送门：编辑传送门平面，或在画布上点两下取线
- 段：新建、复制、删除；改名字、原点、重复
- 撤销 / 重做，带历史记录
- 缩放、平移
- `.gmap` 导入导出

## 两种使用方式

**玩家**

新建世界或打开 `.gmap`，编辑后保存回 `.gmap`，在游戏里「导入 .gmap」。

**开发**

首选项里打开「开发者模式」，文件菜单会出现：

- 打开世界目录
- 导入到世界目录

用于直接编辑游戏 `datafiles/world/` 下的世界。

## 构建

需要 Flutter 3.47+ 和 Windows 的 C++ 构建工具。

```bash
flutter pub get
flutter run -d windows
```

发布构建：

```bash
flutter build windows --release --no-tree-shake-icons
```

`--no-tree-shake-icons` 是必须的：图标通过参数传入，默认裁剪会把它们删掉，运行时显示空白。

打包（构建并附带许可文件）：

```powershell
pwsh -File tool/package_windows.ps1
```

产物在 `dist/GloomyabyssMapEditor/`。

## 快捷键

| 快捷键 | 操作 |
|---|---|
| `Ctrl+Z` | 撤销 |
| `Ctrl+Shift+Z` / `Ctrl+Y` | 重做 |
| `Ctrl+S` | 保存 |

画布：

- 滚轮：缩放
- 中键 / 右键拖拽：平移
- 左键：按当前模式刷地形、放道具、放对象或拾取

## 文件格式

### 世界目录

```
world/
├── terrain.json        地形表
├── props.json          道具表
├── objects.json        可放置对象表
└── <世界名>/
    ├── world.json      世界清单
    └── <段>.seg        段文件
```

`world.json` 主要字段：

```json
{
  "version": 1,
  "segments": [{ "id": "main", "file": "main.seg", "origin": [0, 0] }],
  "portals": [],
  "links": [],
  "seams": [],
  "portal_planes": [],
  "start": { "col": 2, "row": 2 }
}
```

### 段文件

一行一串地形字符，行首 `;` 是指令：

```
; name=overworld
; player=8,12
; prop=box,24,18
; spawn=Obj_Froggit,20,6
; solid=26,4, 30,4, 30,8
################################
................................
```

编辑器会原样保留指令，不解释、不丢失。

### `.gmap`

单文件世界包，不压缩：

```
4 字节   "GMAP"
2 字节   版本号
2 字节   条目数
每条目：
  2 字节  名字长度
  n 字节  名字（UTF-8）
  4 字节  数据长度
  m 字节  数据
```

里面装 `world.json` 和各个 `.seg`。

## 许可

Apache License 2.0，见 [LICENSE](./LICENSE) 与 [NOTICE](./NOTICE)。

第三方组件与许可全文见 [THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md) 和 `licenses/`。
