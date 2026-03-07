# RaymanAgent v159 Release Notes

## 概览

本次版本重点补齐了 Rayman 的发布链路与分发入口，恢复了缺失的运行入口、发布包装层以及关键发布契约辅助能力，使发布产物重新具备可校验、可打包、可分发的状态。

## 本次更新亮点

- 恢复了 Windows 与 Shell 侧的核心入口脚本
- 补齐了 `.dist` 可分发镜像中的关键包装层文件
- 修复了发布契约相关的共享辅助函数与非交互调用行为
- 恢复了运行所需的基础配置文件
- 重新生成并验证了可分发 zip 包

## 主要改进

### 发布入口恢复

已恢复以下入口与包装脚本，使初始化、自检、校验和 watcher 场景重新可用：

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

已恢复 Windows 侧常用辅助脚本，包括：

- `win-check.ps1`
- `win-watch.ps1`
- `win-preflight.ps1`
- `win-proxy-check.ps1`
- `win-oneclick.ps1`
- `win-exitwatch.ps1`

### 发布契约与共享能力修复

针对发布验证路径，本次补齐并修复了关键共享能力：

- 恢复 `config.json`
- 补齐 Git 安全调用辅助逻辑
- 补齐嵌套 `.Rayman` 修复逻辑
- 修复 prompt 更新脚本在非交互环境下的调用行为

## 验证结果

本次版本已完成以下验证：

- 标准发布门禁通过
- 完整发布校验通过
- 可分发 zip 包已生成
- 发布包抽查通过，关键入口文件已包含
- 未发现额外日志文件或运行时残留被打入发布包

## 发布产物

- 文件名：`rayman-distributable-v159-20260307_113842.zip`
- 位置：`.Rayman/release/`

## 已知说明

在当前主机环境下，`copy smoke sandbox strict` 因 Windows Sandbox 权限问题触发 `Access is denied`。本次按仓库既有发布流程，通过显式记录理由的方式完成受控放行，不影响当前产物交付。

## 适用场景

此版本适合用于：

- 恢复 Rayman 分发包的完整结构
- 为后续发布、验收与交付提供稳定基础
- 继续进行远端发布或外部交付前的版本封板

## 简短版文案

RaymanAgent v159 重点修复了发布链路中缺失的入口、包装层与关键契约辅助能力，重新打通了发布校验与可分发打包流程，并生成了经过抽查的分发包，可作为后续交付与发布的稳定基础。
