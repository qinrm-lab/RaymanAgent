---
name: worker-remote-debug
description: Discover a Rayman Worker on the LAN, bind the active worker, sync code, and prepare remote .NET debugging through VS Code pipeTransport.
---

# Worker Remote Debug

Use this skill when the task must run in a Windows work machine that exposes the real runtime environment, while code edits still stay on the dev machine.

## Default Flow

1. Discover workers: `rayman.ps1 worker discover`
2. Inspect cached workers: `rayman.ps1 worker list`
3. Bind one worker: `rayman.ps1 worker use --id <workerId>`
4. Choose sync mode:
   - attached: `rayman.ps1 worker sync --mode attached`
   - staged: `rayman.ps1 worker sync --mode staged`
5. Check remote status: `rayman.ps1 worker status`
6. Prepare debug manifest:
   - launch: `rayman.ps1 worker debug --mode launch`
   - attach: `rayman.ps1 worker debug --mode attach`
7. Start VS Code launch config:
   - `Rayman Worker: Launch .NET (Active Worker)`
   - `Rayman Worker: Attach .NET (Active Worker)`

## Guardrails

- v1 trusts LAN discovery only inside a controlled isolated network.
- Worker is Windows-only and assumes an interactive logged-in user session.
- One dev workspace can discover many workers, but only one active worker is used at a time.
- Source edits remain local; the worker only runs commands, hosts staged code, prepares debugging, and upgrades itself.
- Remote source-level debugging is .NET-first. Other stacks only get remote execution unless explicitly extended.

## Useful Commands

- Remote exec: `rayman.ps1 worker exec -- dotnet build`
- Remote upgrade: `rayman.ps1 worker upgrade`
- Clear active worker: `rayman.ps1 worker clear`
