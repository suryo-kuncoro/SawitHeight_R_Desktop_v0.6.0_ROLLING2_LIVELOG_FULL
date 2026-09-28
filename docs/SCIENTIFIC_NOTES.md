# Scientific Notes — v0.6.0

- P95 is the current primary estimator, not a universal biological truth.
- P99 and Top10/20/30 are retained for internal consistency diagnostics.
- A common DTM is not mandatory; local terrain validity per period is more important for relative height.
- `T_TECH` is a technical uncertainty proxy, not an agronomic growth threshold.
- Small delta with good canopy support is treated as `STABLE_NO_DETECTABLE_CHANGE`, not an automatic residual.
- Residual status is a re-check flag and must not be interpreted automatically as disease, mortality, or agronomic failure.
- The app does not perform automatic ICP; XY alignment must be validated externally when needed.
