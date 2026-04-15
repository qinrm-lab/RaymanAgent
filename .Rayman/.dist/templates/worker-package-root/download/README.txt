This directory contains offline-friendly worker package assets.

- download\vsdbg\
  Preferred local debugger payload. If vsdbg.exe exists here, worker install/debug will use it before attempting any online download.

- download\powershell7\
  Optional troubleshooting payload location for the latest stable PowerShell 7 x64 installer. Worker startup does not require this by default, and export-package will try to refresh it to the newest stable MSI while removing older cached versions.

These files are package-managed assets and may be refreshed whenever worker export-package is run.
