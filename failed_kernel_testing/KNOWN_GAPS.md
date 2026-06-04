# Known Gaps

- Route 28 raw JSON artifacts are not present in this package. The recovery note records that only the markdown survived after reboot.
- Some historical run directories are absolute paths from the original Spark environment and are not bundled here.
- Model weights and Hugging Face cache contents are not included.
- Local env files and API keys are not included.
- The live Apollo tunnel established during packaging is operational state, not a durable deployment artifact.
- K144 MTP2 long-context safety is not established by this package.
- The Warpgate performance-vector loop is a guardrail and research plan, not a successful kernel result.
- Copied scripts are archived in package folders and are not directly runnable in place without restoring the original repository path layout.
- Model-card drafts include some original-publication narrative. Re-check broad quality-suite claims against raw evidence before reusing them as benchmark proof.
