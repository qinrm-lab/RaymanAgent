---
description: Use an active Rayman Worker to run commands in the real Windows work environment, sync code if needed, and prepare remote .NET debugging.
---

{{TASK}}

Constraints:
- Treat the active Rayman Worker as the execution host when the task depends on the real runtime environment.
- Keep code edits on the dev machine unless the task explicitly requires a worker-side upgrade or staging action.
- If the worker has not been selected yet, first discover/list workers and bind one active worker.
- Pick `attached` sync when the work machine already has the correct repo checkout; pick `staged` when local uncommitted changes must be exercised remotely.
- For .NET debugging, prepare the worker debug manifest before asking the user to start `Rayman Worker: Launch .NET (Active Worker)` or `Rayman Worker: Attach .NET (Active Worker)`.
