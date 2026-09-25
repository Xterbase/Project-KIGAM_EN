### `r_runner.py` (while rpy2 is the bridge)

`Analysis.R` is `source()`d once (`_ANALYSIS_LOADED` + `R_LOCK`); every R call runs under
`R_LOCK` inside `default_converter.context()`. rpy2 is not thread-safe — never call
`rpy2.robjects.r[...]` from elsewhere.

**Unpack R vectors through the `r_*_list` / `r_scalar_*` helpers**, never a bare
`int(x) if x is not None`: rpy2 returns per-type NA sentinels, not `None` — `NA_integer_`
arrives as `-2147483648`, `NA_character_` as the string `"NA_character_"` (a `str`
subclass, so `isinstance` won't catch it; `is_r_na()` compares by identity), `NA_real_` as
`nan`.

### Legacy Streamlit layer

The one idea worth carrying into the web build is `state_manager.py`'s invalidation rule:
stages declare `depends_on`, and a changed input invalidates that stage and everything that
depends on it **transitively — by dependency, not by order**. Everything else there
(widget-key rules, `st.session_state` flattening) is Streamlit-specific.
