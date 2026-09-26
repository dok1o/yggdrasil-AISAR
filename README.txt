Debian-based program, stack: Elixir  1.19.5/Python 3.11:

--- Dev-Install: 

dependencies:
* Elixir: dep list in backend/mix.exs updated - should be full, no second-order (will be /deps)
* Python: requirements.txt (will be /venv311)

install.sh: 
* potentially: many warnings about non-significant Elixir 1.19.5 changes
* will dowload ~1GB of deps, mostly PySide6 for Python by size 

--- Settings via GUI, most GUI elements are not interactive yet, two checkboxes in Edit/Settings:

Defaults:
ygg enabled
pf disabled - old scheme, to be fully retired in favor of Yggdrasil network subnode
crawl disabled - random crawling for torrents and parsing them into lines of per-day tjf files, intermediate semantic presentation

--- Tools:

iex Elixir: iex_connect.sh while running

/tools/py_scripts/, some:
* copy_machine.py - PySide GUI for multi-copying modules for promptig AI
* samples_compare.py - with samples logging enabled, generate json log files on two machines and put in working dir for comparison (reads first two jsonl found)

--- Windows Notes: 

* needs .sh rewritten in .bat
* doesn't shard UDP socket in Windows, doesn't have substitution logic yet

=== RUN: magnet_sorter.sh after installing dependencies
