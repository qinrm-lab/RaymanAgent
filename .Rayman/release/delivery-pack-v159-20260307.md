# RaymanAgent v159 最终交付说明

## 交付摘要

本次交付围绕 RaymanAgent 发布链路的恢复与封板开展，已完成缺失入口脚本、包装层、共享发布辅助能力及基础配置的补齐与修复，并形成经校验的可分发交付包。

截至当前，交付状态如下：

- 发布链路已恢复至可校验、可打包、可分发状态
- 可分发 zip 包已生成并完成抽查
- 关键入口文件及包装脚本已确认包含于交付包内
- 本地代码已完成安全拆提交整理
- 当前成果保留于本地仓库，尚未配置远端推送

## 交付物清单

### 1. 分发包

- 文件名：`rayman-distributable-v159-20260307_113842.zip`
- 存放路径：`.Rayman/release/rayman-distributable-v159-20260307_113842.zip`
- 文件大小：`791,887` 字节
- 生成时间：`2026-03-07 11:39:05`

### 2. 内部发布说明

- 文件：`.Rayman/release/release-notes-v159-20260307.md`
- 用途：用于保留技术修复细节、验证过程、已知限制及提交边界

### 3. 对外发布说明

- 文件：`.Rayman/release/public-release-notes-v159-20260307.md`
- 用途：用于发布页面、外部沟通及版本说明场景

### 4. 最终交付说明

- 文件：`.Rayman/release/delivery-pack-v159-20260307.md`
- 用途：用于交付归档、验收沟通、项目留痕与后续交接

## 本次交付范围

### 发布入口与包装层恢复

本次已恢复以下核心入口与包装脚本，以支持初始化、自检、校验及 watcher 相关场景：

- `init.cmd`
- `init.sh`
- `rayman.cmd`
- `rayman-win.cmd`
- `self-check.sh`
- `run/doctor.sh`
- `run/check.sh`
- `run/rules.sh`
- `run/watch.sh`

### Windows 辅助脚本补齐

本次已恢复以下 Windows 侧辅助脚本：

- `win-check.ps1`
- `win-watch.ps1`
- `win-preflight.ps1`
- `win-proxy-check.ps1`
- `win-oneclick.ps1`
- `win-exitwatch.ps1`
- `scripts/watch/stop_background_watchers.ps1`

### 发布契约与共享能力修复

本次已补齐并修复以下关键能力：

- `.Rayman/config.json`
- Git 安全调用辅助逻辑
- 嵌套 `.Rayman` 目录修复逻辑
- prompt 更新脚本在非交互环境下的调用行为
- `.dist` 目录下对应的分发镜像文件

## 验证与验收结论

本次交付已完成并确认以下结果：

- 标准发布门禁通过
- 完整发布校验通过
- 分发包已成功生成
- 分发包抽查通过
- 关键入口文件已包含在 zip 包中
- 未发现额外日志文件被打入交付包
- 未发现额外运行时残留被打入交付包

综合判断，本次交付已满足当前阶段的封板与交付要求。

## 已知说明与边界

- 在当前主机环境下，`copy smoke sandbox strict` 因 Windows Sandbox 权限问题出现 `Access is denied`
- 本次依据仓库既有发布机制，采用“显式记录理由”的受控放行方式完成相关校验
- 该环境限制不影响当前交付包的完整性与可分发状态

## 对应提交记录

建议将本次交付关联至以下提交：

- `c06cd84` — `fix(rayman): restore release contract helpers and config`
- `12c441a` — `feat(rayman): restore release entrypoints and wrappers`
- `cbf22ef` — `docs(release): add v159 release notes`
- `0661f85` — `docs(release): add public v159 release notes`
- `7f4d04f` — `docs(release): add v159 delivery pack notes`

## 建议验收清单

建议按以下顺序执行验收：

- [ ] 确认已接收发布包 `rayman-distributable-v159-20260307_113842.zip`
- [ ] 确认包内包含 `init.cmd`、`init.sh`、`rayman.cmd`、`rayman-win.cmd`
- [ ] 确认包内包含 `self-check.sh` 与 `run/doctor.sh`
- [ ] 确认包内包含 `win-check.ps1` 与 watcher 停止脚本
- [ ] 确认 `.dist` 镜像文件已完整补齐
- [ ] 如需环境复核，可在目标环境执行初始化、自检或校验流程
- [ ] 阅读已知说明，并确认接受 sandbox 受控放行背景

## 建议交付话术（可直接复制）

### 交付通知版本

RaymanAgent v159 已完成交付。本次版本主要完成了发布链路恢复、入口与包装层补齐、共享发布辅助能力修复以及基础配置恢复，并重新生成了经过校验的可分发包。当前交付内容包含分发包、内部发布说明、对外发布说明及最终交付说明，可直接用于验收、归档与后续交接。

### 面向测试/验收同事版本

请优先依据交付清单核对分发包内入口文件与基础脚本完整性；如需进一步验证，可在目标环境执行初始化、自检或发布校验流程。当前版本已完成标准门禁与完整发布校验。已知仅存在当前主机环境下的 Windows Sandbox 权限限制说明，该项不影响本次交付包验收。

### 面向项目记录/周报版本

已完成 RaymanAgent v159 发布整理与交付封板，恢复缺失入口与包装层，修复关键发布契约辅助逻辑，补齐 `.dist` 镜像及基础配置，并重新生成、抽查与归档可分发包及相关说明材料。

## 当前状态

- 当前分支：`master`
- 当前远端：未配置
- 当前工作区：应保持干净
- 当前建议：以本地提交与本地交付物方式保留成果；如后续需要对外推送，再补充远端配置并执行推送流程
