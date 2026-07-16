---
name: aif-hello
description: Placeholder that confirms the AI Foundry set is installed and reachable. Use when the user asks whether AI Foundry is working, or invokes /aif-hello.
---

# aif-hello

A placeholder. It exists so that `aif init` has something real to install and the
harness has something real to invoke — proving the pipeline before the actual
foundry content is written.

When invoked, report exactly three things and nothing else:

1. That the AI Foundry set is installed and reachable.
2. The set version, read from `.aif/manifest.json`.
3. The active profile, read from `.aif/profile.local` if present, otherwise say
   the profile is unset.

Do not offer to do anything further. This skill is a wire test, not a feature.
