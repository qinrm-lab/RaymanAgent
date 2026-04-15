Place a complete offline vsdbg payload in this directory.

Expected layout:
- download\vsdbg\vsdbg.exe
- additional files/subdirectories that ship with the same vsdbg build

When present, worker install/debug will copy this directory into .Rayman\tools\vsdbg and prefer it over any online download.
