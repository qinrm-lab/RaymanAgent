# RaymanAgent 发布说明（v159）

## 产物

- 发布包：`e:\rayman\software\RaymanAgent\.Rayman\release\rayman-distributable-v159-20260307_113842.zip`
- 大小：`791,887` 字节
- 打包时间：`2026-03-07 11:39:05`

## 本次变更摘要

### 1. 恢复发布契约辅助函数与配置

对应提交：`c06cd84 fix(rayman): restore release contract helpers and config`

- 恢复 `.Rayman/config.json`
- 在 `.Rayman/common.ps1` 与 `.Rayman/.dist/common.ps1` 中补齐：
  - `Invoke-RaymanGitSafe`
  - `Repair-RaymanNestedDir`
- 修复 `.Rayman/scripts/release/contract_update_from_prompt.sh` 与 `.dist` 镜像中的非交互调用行为

### 2. 恢复发布入口与包装层

对应提交：`12c441a feat(rayman): restore release entrypoints and wrappers`

- 恢复 Windows / Shell 入口：
  - `init.cmd`
  - `init.sh`
  - `rayman.cmd`
  - `rayman-win.cmd`
  - `self-check.sh`
- 恢复 `run/` 下包装层：
  - `doctor.sh`
  - `check.sh`
  - `rules.sh`
  - `watch.sh`
- 恢复 Windows 侧辅助脚本：
  - `win-check.ps1`
  - `win-watch.ps1`
  - `win-preflight.ps1`
  - `win-proxy-check.ps1`
  - `win-oneclick.ps1`
  - `win-exitwatch.ps1`
- 恢复 watcher 停止脚本：
  - `.Rayman/scripts/watch/stop_background_watchers.ps1`
- 恢复 `.dist` 对应镜像
- 恢复 `codex_fix_prompt.txt`

## 验证结论

- 标准发布门禁：已通过
- 完整发布校验：已通过
- 已生成可分发 zip 包
- 抽查 zip 内容：
  - 关键入口脚本均存在
  - 未发现额外日志文件
  - 未发现额外运行时文件

## 注意事项

- `copy smoke sandbox strict` 在当前主机环境下因 `Access is denied` 失败
- 本次按仓库内置机制，通过显式 bypass 放行并保留理由记录
- 当前仓库已完成安全拆提交，工作区干净

## 推送状态

- 当前分支：`master`
- 当前未配置任何 Git 远端
- 因此当前只能本地保留提交，尚不能直接推送

## 如需继续发布，可执行的后续动作

1. 配置远端并推送当前 `master`
2. 基于当前 zip 包进行交付
3. 将本说明整理为正式 release notes / changelog
