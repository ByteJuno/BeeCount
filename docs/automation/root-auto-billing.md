# Android 内置 Root 自动记账（实验性）

此功能直接集成在 BeeCount APK 中，不依赖 AutoAccounting、LSPosed 模块、外部广播或手动截图。它在设备解锁、支持的微信/支付宝付款页面位于前台时，通过用户授予的 Root 权限读取页面节点；解析、分类与入账均在本机完成，不使用云端 AI。

## 使用范围

- Android 8 及以上、已取得 Root 的设备；仅直装 APK 提供。
- 默认关闭。用户在「智能记账 → Root 无感记账（实验性）」明确开启并授予 Root；通知中可随时停止。
- 只支持人民币个人账本、简体中文支付结果和详情页面。不会打开、点击或滚动支付应用。
- 仅当实付金额、交易号、近期付款时间、商户、付款账户和用户分类规则全部明确时自动入账。付款时间必须处于观察时间前 10 分钟至后 2 分钟之间。
- 没有交易号或时间的付款成功页、退款、转账、提现和还款保留待核对。首版不会把退款自动当收入，也不会猜测转账用途。
- 首版没有实现退款与原交易关联的账本模型。待核对结果不改变任何账户余额，可在核对账本后忽略。
- 自动分类只使用用户设置的商户关键词规则；长关键词优先，等长冲突不入账。余额账户由用户明确映射；银行卡须唯一匹配账户中已配置的银行名称及后四位。

付款页面必须停留至采集完成；快速退出、页面信息不完整、受保护页面或厂商限制可能导致漏识别。此功能仍然需要定期对账，不保证覆盖所有交易。

## 实现与边界

1. `RootBillingService` 是用户启动的前台服务。锁屏、非支付应用及微信聊天/首页不采集；识别不到的 Activity 不扩大到全应用监听。
2. Root 子进程从安装的 APK 加载 `RootBillingWindowReader`，只读取目标包的节点文本，不保存截图、XML 或完整页面到磁盘，不向系统日志输出页面内容。私有平台 API 不可用时失败停止。
3. `UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES` 保留用户已有无障碍服务。没有注册 `AccessibilityService`，也没有执行付款或注入输入事件。开启前先探测连接而不读取页面；系统只允许一个 UiAutomation 会话，其他工具占用时拒绝启动，不抢占或关闭已有会话。
4. Root 命令由原生代码固定构造；Dart、页面文字和外部 Intent 都不能传入 shell 命令。命令有输出上限和超时。
5. 前后台复用同一个 FlutterEngine 和 ProviderContainer；不再次执行 `main()`，不另建后台数据库连接。进程被系统终止后不会偷偷拉活，用户需重新开启。
6. `root_billing_events` 与交易在同一 SQLite 事务提交，凭据按平台、交易类型及交易号产生稳定键。同单重放不覆盖人工分类或恢复已删除交易。待核对记录可在后续页面补齐，冲突金额保持待核对。普通商户订单号不能代替平台交易号；与截图、手工记账或账单导入之间的交易身份匹配尚未实现。
7. 入账后走现有 `PostProcessor` 刷新与同步；同步失败不回滚本地记录、不重新创建交易。Root 观察凭据是本机数据，不作为云同步实体，因此跨设备同时采集的去重不在首版保证范围内。
8. Play 构建在 Dart 隐藏入口、原生拒绝启动，并在发布流水线的 Manifest overlay 中剥离 Root 服务与专用前台服务权限。

## 验证

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n
flutter test test/services/automation test/services/billing
flutter build apk --debug --flavor dev --target-platform android-arm64
cd android
./gradlew :app:testDevDebugUnitTest
```

自动测试覆盖同单重复/并发投递、同额两笔、进程控制器重建、人工分类保护、删除后重放、优惠实付、历史交易、退款转账不入普通收支、明确账户与规则匹配。

实机还应核对：Root 授权拒绝与撤销；锁屏停止；聊天页不采；付款及详情页切换；应用退至后台或 Activity 重建；通知停止；进程终止；系统 API 不兼容；页面快速退出。构建和模拟页面测试不能证明真实支付页适配。

## 与现有 PR 的关系

- [#183](https://github.com/TNT-Likely/BeeCount/pull/183) 是外部广播入账接口；本功能没有新增外部写入入口。
- [#321](https://github.com/TNT-Likely/BeeCount/pull/321) 是无障碍摇一摇截图；本功能不依赖该 PR，也没有复制其中的采集或保活实现。

该原型代码为独立实现，没有移植 AutoAccounting 的 GPL 代码。是否接纳 Root 功能及相应分发边界仍由项目维护者决定。
