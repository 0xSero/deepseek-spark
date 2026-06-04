# Provenance

## Package Source

Package assembled from local workspace:

```text
source workspace: /home/frosty40/ds0
package worktree: /home/frosty40/ds0-failed-kernel-package
base branch: origin/main
package branch: codex/failed-kernel-testing-package
```

## Source Commit Context

The package worktree starts from upstream `origin/main` at:

```text
3555785 Update README.md
```

Some copied research artifacts came from the active local ds0 workspace, which contained later tracked and untracked research files. The package intentionally copies those artifacts into a clean branch rather than publishing the dirty local branch.

## Packaging Session Live API Check

During this packaging session:

```text
container: studio-deepseek-v4-flash-spark-18000
local endpoint: http://127.0.0.1:18000/v1
Apollo endpoint: apollo 127.0.0.1:18000
model id: DeepSeek-V4-Flash-Spark
max_model_len reported by /v1/models: 200000
chat smoke response content: DEEPSEEK_APOLLO_READY
```

The live check was used to confirm serving status only. Historical benchmark claims should be traced to the evidence files and context-eval JSON.

## Evidence Rules

- Treat markdown evidence notes as the surviving run record only for the condition they state.
- Treat context-eval JSON as raw machine-readable outputs for the corresponding May 31 context eval runs.
- Do not infer missing raw Warpgate JSON from the route 28 markdown note.
- Do not compare route 28 results against a different shape, context-token condition, dtype, or comparator.
- Do not compare stock baseline and custom kernel work unless the benchmark protocol and serving condition match.
- Treat copied model cards as publication drafts. Any broad quality or full-suite claim must be checked against the bundled evidence or the original external evidence before reuse.

## Network And Path Sanitization

Public package copies use placeholders for private network defaults:

```text
<spark-tailnet-ip>
<spark-root>
<repo-root>
```

Absolute paths inside historical evidence notes are retained as provenance records. They are not portable defaults.
