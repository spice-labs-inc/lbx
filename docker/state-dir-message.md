# What this directory is

The VMs and Docker running inside a box (an isolated coding session)
store their larger files here — VM disk images, Docker image data, and
similar bulky state. The files live on the host's drive because the
box's own guest drive is small and would otherwise fill up quickly.

Notes for the LLM or human who finds this directory:

- The contents are machine state, not project files. If this directory
  sits inside a git repository, add it to `.gitignore`.
- A running box may be using these files right now. Deleting them while
  a box is running will break that box; wait until it is stopped first.
- The directory can grow very large — that is normal.