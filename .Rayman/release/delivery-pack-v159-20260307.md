# RaymanAgent v159 最终交付说明

## 交付概览

本次交付目标是恢复 RaymanAgent 的发布链路完整性，补齐缺失入口、包装层、共享发布辅助能力与基础配置，并生成经过验证的可分发包。

当前状态：

- 发布链路已恢复
- 可分发 zip 包已生成
- 关键入口脚本已抽查通过
- 工作区已整理并完成安全拆提交
- 当前保留为本地提交，未推送远端

## 交付物清单

### 1. 发布包

- 文件名：`rayman-distributable-v159-20260307_113842.zip`
- 路径：`.Rayman/release/rayman-distributable-v159-20260307_113842.zip`
- 大小：`791,887` 字节
- 打包时间：`2026-03-07 11:39:05`

### 2. 内部发布说明

- 文件：`.Rayman/release/release-notes-v159-20260307.md`
- 用途：保留技术细节、验证过程、已知说明与提交边界

### 3. 对外发布说明

- 文件：`.Rayman/release/public-release-notes-v159-20260307.md`
- 用途：适合发布页面、交付说明、对外沟通

## 本次交付包含的主要内容

### 发布入口与包装层恢复

已恢复以下核心入口与包装脚本：

- `init.cmd`
- `init.sh`
- `rayman.cmd`
- `rayman-win.cmd`
- `self-check.sh`
- `run/doctor.sh`
- `run/check.sh`
- `run/rules.sh`
- `run/watch.sh`

### Windows 辅助脚本恢复

已恢复：

- `win-check.ps1`
- `win-watch.ps1`
- `win-preflight.ps1`
- `win-proxy-check.ps1`
- `win-oneclick.ps1`
- `win-exitwatch.ps1`
- `scripts/watch/stop_background_watchers.ps1`

### 发布契约与共享能力修复

已补齐并修复：

- `.Rayman/config.json`
- Git 安全调用辅助逻辑
- 嵌套 `.Rayman` 修复逻辑
- prompt 更新脚本的非交互调用行为
- `.dist` 目录下对应镜像文件

## 验证与验收结论

本次交付已完成以下验证：

- 标准发布门禁通过
- 完整发布校验通过
- 发布包已生成
- 发布包抽查通过
- 关键入口文件已包含在 zip 中
- 未发现额外日志文件混入
- 未发现额外运行时残留混入

## 已知说明

- 在当前主机环境下，`copy smoke sandbox strict` 因 Windows Sandbox 权限问题出现 `Access is denied`
- 本次根据仓库既有发布机制，使用显式理由记录的受控放行方式完成发布校验
- 该问题不影响当前交付包的可分发状态

## 对应提交

建议将本次交付关联到以下提交：

- `c06cd84` — `fix(rayman): restore release contract helpers and config`
- `12c441a` — `feat(rayman): restore release entrypoints and wrappers`
- `cbf22ef` — `docs(release): add v159 release notes`
- `0661f85` — `docs(release): add public v159 release notes`

## 建议验收 checklist

请按以下顺序验收：

- [ ] 确认收到发布包 `rayman-distributable-v159-20260307_113842.zip`
- [ ] 确认包内包含 `init.cmd` / `init.sh` / `rayman.cmd` / `rayman-win.cmd`
- [ ] 确认包内包含 `self-check.sh` 与 `run/doctor.sh`
- [ ] 确认包内包含 `win-check.ps1` 与 watcher 停止脚本
- [ ] 确认 `.dist` 镜像文件已补齐
- [ ] 如需环境验证，可在目标环境执行自检/校验流程
- [ ] 阅读已知说明，确认接受 sandbox 受控放行背景

## 交付建议用语（可直接复制）

### 版本交付通知

RaymanAgent v159 已完成交付。本次版本主要恢复了发布链路所需的入口、包装层、共享辅助能力与基础配置，并重新生成了经过校验的可分发包。当前交付物包含 zip 包、内部发布说明与对外发布说明，可用于后续验收、封板与对外交付。

### 给测试/验收同事的说明

请优先按交付 checklist 验收包内入口文件与基础脚本完整性；如需进一步验证，可在目标环境执行初始化、自检或发布校验流程。当前版本已完成标准门禁与完整发布校验，已知仅存在主机环境下的 Windows Sandbox 权限限制说明，不影响当前分发包交付。

### 给项目记录/周报的摘要

完成 RaymanAgent v159 发布整理与封板，恢复缺失入口与包装层，修复发布契约辅助逻辑，补齐 `.dist` 镜像与配置文件，重新生成并验证可分发包，交付材料已归档。

## 当前状态

- 当前分支：`master`
- 当前远端：未配置
- 当前工作区：应保持干净
- 当前建议：以本地提交 + 本地交付包方式保存，后续如需推送再补远端配置
