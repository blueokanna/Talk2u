# 设计系统：Material 3 Expressive

这份文档描述 Talk2U 的界面契约。它不是“风格建议”，而是代码里已经在执行的规则：形状只有一套刻度，动效只有一套 token，环境动画只有一个时钟。任何页面想偏离这套规则，都必须先改这里，再改代码。

约束前提：

- Flutter 3.47.9 / Dart 3.13.7；
- 只允许 Material 3 与 Material 3 Expressive 组件；
- 不再出现 Material 2 的组件变体、手写圆角、散落的 `Curves.*` 或 `Colors.*` 常量；
- 所有动效在系统“减弱动态效果”（`MediaQuery.disableAnimations`）下必须静止到最终状态，而不是“更快地播完”。

## 1. 形状：`AppShapes`

形状刻度来自 Material 3 shape scale，定义在 `lib/src/theme/app_shapes.dart`：

| token | 半径 |
| --- | ---: |
| `extraSmall` | 4 |
| `small` | 8 |
| `medium` | 12 |
| `large` | 16 |
| `extraLarge` | 28 |
| `pill` | `StadiumBorder` |

语义角色把 token 绑定到组件，调用方不再自己挑数字：

| 角色 | 形状 | 使用者 |
| --- | --- | --- |
| `surface` | 28 dp `RoundedSuperellipseBorder` | Card、Dialog、空状态容器 |
| `overlay` | 8 dp 超椭圆 | 菜单、SnackBar |
| `field` | 12 dp 超椭圆 | 输入框、思考面板、错误条、列表选中行 |
| `sheet` | 顶部 28 dp 超椭圆 | 底部面板、启动状态条 |
| `drawer` | 朝向内容一侧 28 dp 超椭圆 | 抽屉 |
| `fab` | 16 dp 超椭圆 | 浮动操作按钮 |
| `pill` | 胶囊 | 按钮、Chip、输入法发送键 |
| `badge` | 8 dp 超椭圆 | 标签、思考标记 |
| `bubbleRadius(mine:)` | 三个 28 dp 角 + 靠头像一角 8 dp | 对话气泡 |

为什么用 `RoundedSuperellipseBorder`：它是连续曲率（squircle），在相同半径下比圆弧更接近 Material 3 Expressive 的大容器轮廓，也消除了圆弧在卡片边缘的曲率突变。气泡的非对称圆角由 `BorderRadius.only` 表达，尾角收窄到 `small`，不需要第二个 Path。

约束：`lib/` 下不允许出现 `BorderRadius.circular(`、`RoundedRectangleBorder(`、`BoxShape.circle`（头像除外）。测试 `test/rendering/design_system_test.dart` 锁定了 scale 数值和气泡尾角方向。

## 2. 动效：`AppMotion`

`lib/src/theme/app_motion.dart` 直接引用 Flutter 导出的 Material token，而不是复述数字：

- 时长：`Durations.short2`(100 ms)、`short3`(150)、`short4`(200)、`medium1`(250)、`medium2`(300)、`medium3`(350)、`medium4`(400)、`long2`(500)；
- 曲线：`Easing.emphasizedDecelerate`、`emphasizedAccelerate`、`standard`、`standardAccelerate`、`standardDecelerate`。

语义别名：`micro`、`small`、`tap`、`resize`、`swap`、`enter`、`page`、`emphasis`。

Flutter 3.47 没有导出命名 spring token，因此 App 只编码一条“空间弹簧”参数：`SpringDescription(mass: 1, stiffness: 1400, damping: 64)`，阻尼比约 0.86。`AppMotion.springTo` 是唯一入口，避免每个调用点各写一套欠阻尼参数。它只用于需要轻微过冲的交互；减弱动效时直接落到终值。

页面转场（`FluidPageTransitionsBuilder`）：

- 前进 400 ms、返回 300 ms；
- 入场水平位移 3.5%，缩放 0.985 → 1，**整页从第一帧起保持不透明**；
- 出场沿同轴后退、淡出 25%；
- 减弱动效时直接返回子页面，**不**挂载第二层动画树（测试断言 `identical(transition, child)`）。

入场不做整页透明度动画是有意的：`Scaffold` 的背景如果跟着路由从 0 淡入，入场页的极光/内容会先透出上一页的 Live2D 平台视图，用户看到的就是“先出设置内容，背景后到，模型还在”。现在背景与内容作为一个不透明页面一起进入；出场页仍然淡出 25%，保持共享轴的纵深感。

共享轴内容切换（`FluidSwitcher`）：

- 300 ms；
- 入场位移 4%（垂直）/ 6%（水平），缩放 0.98 → 1；
- 出场沿同轴反向淡出，并用 `IgnorePointer` 隔离；
- 子组件必须带 key，否则不猜测身份、直接返回原 child；
- 动画途中再次替换时用 generation 计数保护，旧 `whenComplete` 不会清掉新转场的 outgoing child。

## 3. 极光引擎：单时钟、按路由挂载的渲染层

`lib/src/rendering/aurora_engine.dart` 与应用同生命周期：

- 整个 App 只有一个 `Ticker`，相位通过 `AuroraClock`（`ChangeNotifier`）广播；
- 通知上限 30 Hz：28 秒周期的漂移不需要 60 帧；
- `AppMotionScope` 把 Ticker 与后台生命周期绑定；`disableAnimations` 时停表并停在 30% 相位的确定性画面；
- 恢复前台时以当前相位重新起算，不会因为后台时长而跳帧。

`lib/src/widgets/aurora_backdrop.dart` 是渲染层：

- **兜底路径先填一层不透明 `surface`**，再画径向渐变；首帧或光栅化失败时也不会把上一张路由透出来；
- 主题/尺寸稳定 180 ms 后，把三层径向渐变**一次性**光栅化为 `ui.Image`（逻辑尺寸的 55%，最长边上限 1600 px）；
- 此后每帧只做一次 `drawImageRect` 平移 blit（8% 溢出边距，水平 ±1.5%、垂直 ±1.2% 漂移），不再构造 shader、不再重画全屏渐变；
- 主题动画期间不会逐帧光栅化：签名变化只重置去抖计时器；
- 旧 `ui.Image` 在下一帧后释放，避免正在绘制的图层引用已释放纹理；
- 光栅化失败时保留渐变兜底，不把异常抛进 App 外壳。

渲染层**挂在需要极光的路由内部**，而不是挂在 `Navigator` 之上。`ChatPage` 是 Live2D 平台视图（不透明），不需要极光；`SettingsPage`、`CharacterListPage`、`CharacterEditPage` 各自挂一个 `AuroraBackdrop`。这样一次只有一个可见极光在绘制，转场时入场页的极光是**不透明**的，不会让上一页的 Live2D 透出来。`ChatPage` 自身的 `Scaffold` 明确使用 `colorScheme.surface`，避免平台视图或 AppBar 后面落到窗口默认黑底。聊天路由失去 `isCurrent` 时，Live2D 子树同时进入 `Offstage` 与 `TickerMode(enabled: false)`，平台视图不再参与合成。

Live2D 的原生 clear color 也跟随 `colorScheme.surface`：创建时通过 `creationParams.backgroundColor` 传入，主题切换时由 `setBackgroundColor` 在渲染线程更新。这样浅色主题不会留下黑色清屏，深色主题也不会残留浅色底。

这是 Dart 侧的真实优化，不是“把渲染交给系统”。Flutter 没有暴露把脚手架背景直接交给引擎合成的 API；本文档只描述已经落地的缓存与调度，不宣称不存在的渲染层能力。

## 4. 组件映射

| 旧写法 | 现写法 |
| --- | --- |
| `Container + BoxDecoration(borderRadius)` | `Material(shape: AppShapes.*)` 或 `ShapeDecoration` |
| `AnimatedSwitcher` + 手写 Fade/Slide | `FluidSwitcher`（共享轴） |
| `AnimatedCrossFade` 思考面板 | `Expansible`（M3 Expressive）+ `ThinkingSection` |
| 手写 `InkWell + Container` 动作胶囊 | `ActionChip` |
| `DropdownButtonFormField` + `DropdownMenuItem`（MD2 风格展开层） | `DropdownMenu`（M3）：`selectOnly: true`、`requestFocusOnTap: false`、`expandedInsets: EdgeInsets.zero`，菜单形状走 `AppShapes.overlay` |
| `PopupMenuButton` 定制 shape | 主题 `popupMenuTheme`；新代码优先 `MenuAnchor` |
| `ElevatedButton` / 自带阴影的旧按钮 | `FilledButton` / `OutlinedButton` / `TextButton` |
| `Colors.blue/green/white` | `ColorScheme` 语义角色 |
| 手写拖拽条 | `BottomSheetThemeData(showDragHandle: true)` |
| `Container(color:)` 状态条 | `Material(color:, shape:)` |

设置页的端侧模型卡片也是这套规则的一部分：Qwen 卡片按原生 `capabilities.presets` 列出**两个** Qwen3-4B-Instruct-2507 身份，安装动作通过 `MenuAnchor` 选择 AI Hub 下载、QAIRT 导入或 GGUF 导入；已安装身份用 `Chip` 标记，不再用一行“the model”掩盖上游 checkpoint。

## 5. 新代码准入清单

1. 形状只用 `AppShapes`；需要新形状先加语义角色，不在页面里写数字。
2. 时长/曲线只用 `AppMotion`；需要新曲线先加 token。
3. 颜色只用 `ColorScheme`；`Colors.transparent` 仅用于“明确无底色”的 Material。
4. 过渡用 `FluidSwitcher`；页面转场不要自定义 `PageRouteBuilder`。
5. 常驻动画必须挂在 `AuroraEngine` 的相位上，不新增独立 `Ticker`。
6. 任何动画都要在 `AppMotionPolicy.animate == false` 时落到终值。
7. 跑 `dart analyze lib test` 与 `flutter test`；设计系统测试会拦住 token 漂移。

## 6. 验证

```powershell
dart analyze lib test
flutter test
```

`test/rendering/design_system_test.dart` 覆盖：

- shape scale 数值与气泡尾角方向；
- 减弱动效下极光时钟停表并停在 30%；
- 时钟 1 秒内通知不超过 31 次；
- `FluidSwitcher` 在减弱动效时不产生额外的透明度层；
- 共享轴切换期间同时存在出入两层，结束后只剩一层。
