# Devilking MP管理

作者与维护者：[dakotazhang](https://github.com/dakotazhang)。

原生 iPhone 家庭媒体管理工具：在外发现影视、搜索片名、追订电影和剧集，查看家中下载与长期做种情况。iOS 16.1+，SwiftUI，直接连接现有服务，无需额外部署后台。

**1.1.0 公开测试版** · [下载安装包与更新记录](https://github.com/dakotazhang/Devilking-MP/releases/tag/v1.1.0)。 已通过102项接口与保护测试、3项模拟器界面测试和arm64安装包校验。[新版9张界面截图](docs/screenshots/v1.1.0/README.md)来自iOS26.5模拟器合成资料；iOS16.1真机状态栏、外出VPN与实际订阅操作仍待复测。

## 五个常用页面

| 页面 | 用途 |
| --- | --- |
| 仪表盘 | 上传/下载速率、做种/下载/校验/停止/异常任务数量、下载器状态、目录剩余空间与刷新时间 |
| 下载器 | qB1、qB2、TR 的任务搜索、分类与标签、校验状态；授权后的单项启停与 Mbps 上传限速 |
| 发现 | 浏览 MoviePilot 影视推荐、搜索电影/剧集/动漫资料，查看简介并明确选季订阅 |
| 订阅 | 单独查看已有追订与进度；授权后暂停或恢复单条订阅 |
| 设置 | 连接导入、全局只读锁、单服务权限、迁移保护与应用锁 |

Emby 旧连接配置保留兼容，本版主导航专注订阅和下载器管理。应用不提供视频播放。

## 操作前先解锁

全局只读锁默认开启。关闭只读锁后，还需要开启对应服务的管理权限；qB1/TR 的迁移保护独立生效。浏览推荐、搜索影视资料、查看任务和仪表盘均可在只读状态使用。

**新增订阅会让 MoviePilot 按其现有规则自动搜索，并可能下载匹配资源。** 每次提交都需要确认。结果不明时保存本机待核对记录，跨页面或重启后也不会自动重发；先只读核对原订阅。

没有删除数据、移动路径、重新校验、整库启停或 Tracker 手动汇报入口。本人发布和正在/等待校验的任务继续受保护。

## 安装与连接

安装包在本项目 [Releases](https://github.com/dakotazhang/Devilking-MP/releases/latest) 提供。支持的系统使用 TrollStore，或使用自己的有效证书重签；项目不提供证书。最低 iOS 16.1，Bundle ID 保持 `top.devilkkkkk1.DevilkingMP`。

首次在设置填写自己的服务，或在本地填写[连接模板](examples/connection.example.dkmp)后导入。**真实密码、Token、Cookie、受限链接和家庭导入文件不得提交仓库。** 登录资料存入本机钥匙串。

外出先连接已有家庭 VPN，再访问原有内网服务。应用以前台和手动刷新为主，iOS 后台不持续轮询。

详细步骤见[使用与安装](docs/使用与安装.md)。

## 构建与验证

Mac 安装 Xcode、XcodeGen 后执行：

```sh
bash scripts/build-ios.sh all
```

工作流使用合成接口与模拟器测试生成普通沙盒无签名 IPA，不需要 Apple 证书或真实家庭账号。1.1.0 已完成编译、102项接口与保护测试、3项模拟器界面测试及安装包校验；真机和实际业务验证按本页边界记录。

协议与测试边界见[API 契约](docs/api-contract.md)、[审查与验收清单](docs/review-notes.md)。新版界面截图与构建结果随对应测试产物记录。

## 致谢与许可

感谢 [OiiQT](https://github.com/gangz1o/OiiQT) 等社区项目提供功能和协议参考；本项目使用独立客户端实现。来源与第三方许可见[致谢](docs/ACKNOWLEDGEMENTS.md)。

原始代码采用 [MIT](LICENSE)。角色主题图标的权利说明见[素材声明](docs/ASSETS.md)。
