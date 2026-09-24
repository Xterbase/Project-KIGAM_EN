# version1_streamlit/utils/model_recommend.py
"""De distribution metrics -> CAM/MAM/FMM recommendation (deterministic).

Reproducibility is the reason this module exists. The same input + the same
thresholds always produce the same model. Thresholds and sigmab are factors
that change the result, so they are carried in the return value
(thresholds/signals) for the record — the same reason SAR carries
signal_params in its result (just as the integral changes De, sigmab changes
the FMM determination. CA1 fixture: sigmab 0.15 -> FMM, 0.30 -> not FMM).

This recommendation does not replace the researcher's judgment; it's a guide
that assists it. It returns the supporting metrics alongside the pick, so the
researcher can see why that model was chosen and, if needed, change the
thresholds/sigmab and look again. (Project principle: the same stance as "SAR
classifies, it does not filter" — the basis for a determination is never
hidden.)

The statistics themselves (OD, skewness, FMM BIC) are computed in
R (Luminescence) and passed in. This module only holds the decision logic
that maps those metrics to literature-based rules (pure Python, no R needed).

Threshold sources
------------------
- OD_LOW_PCT: even a well-bleached sample commonly shows overdispersion up to
  ~20%. Arnold & Roberts (2009); Galbraith & Roberts (2012, Quaternary
  Geochronology).
- BIC_STRONG: the minimum ΔBIC for a multi-component fit to be "strongly"
  preferred over a single-component fit. 6-10 = strong evidence on the
  Kass & Raftery (1995) approximate scale.
- SIGMAB_DEFAULT: the assumed within-component overdispersion for FMM.
  Roberts et al. (2000); Galbraith & Roberts (2012). The result is sensitive
  to this, so it's meant to be adjusted by the researcher.
- Skewness significance: twice the skewness standard error
  SES = sqrt(6n(n-1)/((n-2)(n+1)(n+3))) is used as the threshold. Diagnosing
  partial bleaching via skewness follows Bailey & Arnold (2006).
"""

import math

# --- Thresholds (literature-backed, part of the deterministic contract) ---
OD_LOW_PCT = 20.0
BIC_STRONG = 6.0
SIGMAB_DEFAULT = 0.15


def _skewness_se(n: int) -> float:
    """Standard error of sample skewness (assuming normality). Standard formula."""
    return math.sqrt(6 * n * (n - 1) / ((n - 2) * (n + 1) * (n + 3)))


def recommend_age_model(od_rel: float | None, skewness: float | None, n: int, fmm: dict | None = None) -> dict:
    """De distribution metrics -> recommended model + rationale.

    Decision tree (OD gate first):
      1. OD < OD_LOW_PCT                    -> CAM  (well-bleached single population)
      2. (OD high) significant positive skew -> MAM  (partial bleaching: asymmetric upper tail)
      3. (OD high) multimodal (ΔBIC > strong) -> FMM  (discrete mixture)
      4. otherwise                           -> CAM  (high overdispersion but no structural evidence)

    Skewness (MAM) is checked before multimodality (FMM): positive skew is
    the classic signal of partial bleaching, and MAM is the model that
    targets it. When skewness isn't clearly present, discrete components
    (FMM) are checked instead. This ordering is a literature-based heuristic
    the researcher can overrule after looking at the signals.

    fmm: the fit_finite_mixture result dict, or None if it wasn't fitted
         (e.g. insufficient sample). Required keys: delta_bic, best_k, sigmab.
    Returns: {model, reasons, signals, thresholds}
    """
    n = int(n)

    # The OD gate is the root of the whole tree. Without an OD value (e.g. no
    # variance), the determination itself is impossible.
    if od_rel is None:
        raise ValueError("Cannot recommend a model because OD (overdispersion) could not be computed (e.g. no variance).")

    skew_crit = 2 * _skewness_se(n)
    # If skewness is None (e.g. zero variance), only skip the partial-bleaching
    # (MAM) check — OD/FMM remain valid.
    skew_known = skewness is not None
    positively_skewed = bool(skew_known and skewness > skew_crit)
    dbic = fmm.get("delta_bic") if fmm else None
    multimodal = bool(dbic is not None and dbic > BIC_STRONG)

    reasons: list[str] = []

    if od_rel < OD_LOW_PCT:
        model = "CAM"
        reasons.append(f"Overdispersion {od_rel:.1f}% < {OD_LOW_PCT:.0f}% → well-bleached single population")
    elif positively_skewed:
        model = "MAM"
        reasons.append(
            f"Overdispersion {od_rel:.1f}% high + positive skew {skewness:.2f} > threshold {skew_crit:.2f} "
            f"→ partial bleaching (asymmetric upper tail)"
        )
    elif multimodal:
        model = "FMM"
        reasons.append(
            f"Overdispersion high, no significant skew, BIC prefers {fmm['best_k']} component(s) over "
            f"single with ΔBIC {fmm['delta_bic']:.1f} (>{BIC_STRONG:.0f}) → discrete mixture"
        )
    else:
        model = "CAM"
        reasons.append(
            f"Overdispersion {od_rel:.1f}% is high but there is no significant skew or multimodality evidence → CAM (note the high overdispersion)"
        )
        if fmm is None:
            reasons.append("FMM could not be fitted (e.g. insufficient sample), so multimodality could not be checked")

    if not skew_known and od_rel >= OD_LOW_PCT:
        reasons.append("Skewness could not be computed (e.g. insufficient variance), so the partial-bleaching (MAM) check was skipped")

    return {
        "model": model,
        "reasons": reasons,
        "signals": {
            "od_rel": od_rel,
            "skewness": skewness,
            "skew_crit": skew_crit,
            "positively_skewed": positively_skewed,
            "multimodal": multimodal,
            "n": n,
            "fmm_delta_bic": (fmm.get("delta_bic") if fmm else None),
            "fmm_best_k": (fmm.get("best_k") if fmm else None),
            "sigmab": (fmm.get("sigmab") if fmm else None),
        },
        "thresholds": {
            "od_low_pct": OD_LOW_PCT,
            "bic_strong": BIC_STRONG,
            "sigmab_default": SIGMAB_DEFAULT,
        },
    }


# ============================================================
# Self-check
# ============================================================
# There's a branching decision tree with boundary values, so each branch and
# boundary is checked here.
# Run: venv/bin/python version1_streamlit/utils/model_recommend.py

if __name__ == "__main__":
    # Regression-pinned on real metrics observed from fixture(ExampleData.DeValues, sigmab=0.15).
    # CA1: OD 34.7%, skew -0.04, multimodal (ΔBIC 95.5) -> FMM
    ca1 = recommend_age_model(
        od_rel=34.69, skewness=-0.037, n=62,
        fmm={"delta_bic": 95.5, "best_k": 3, "sigmab": 0.15},
    )
    assert ca1["model"] == "FMM", ca1["model"]
    assert ca1["signals"]["multimodal"] is True

    # BT998: OD 8.0% -> CAM via the OD gate. (skew 1.34 is large, but with low OD, CAM is still correct)
    bt = recommend_age_model(
        od_rel=8.02, skewness=1.34, n=25,
        fmm={"delta_bic": -6.4, "best_k": 2, "sigmab": 0.15},
    )
    assert bt["model"] == "CAM", bt["model"]

    # MAM branch: high OD + significant positive skew. n=30 -> skew_crit ≈ 0.86.
    mam = recommend_age_model(od_rel=45.0, skewness=1.2, n=30, fmm={"delta_bic": 0.0, "best_k": 2, "sigmab": 0.15})
    assert mam["model"] == "MAM", mam["model"]

    # High OD + no skew + not multimodal -> CAM fallback
    fallback = recommend_age_model(od_rel=40.0, skewness=0.0, n=50, fmm={"delta_bic": 2.0, "best_k": 2, "sigmab": 0.15})
    assert fallback["model"] == "CAM", fallback["model"]
    assert fallback["signals"]["multimodal"] is False

    # Skewness (MAM) takes priority over multimodality (FMM): if both apply, MAM wins.
    both = recommend_age_model(od_rel=50.0, skewness=1.5, n=40, fmm={"delta_bic": 50.0, "best_k": 3, "sigmab": 0.15})
    assert both["model"] == "MAM", both["model"]

    # fmm=None (FMM not fitted): multimodality can't be determined -> CAM fallback, reason states "not fitted".
    no_fmm = recommend_age_model(od_rel=40.0, skewness=0.0, n=50, fmm=None)
    assert no_fmm["model"] == "CAM", no_fmm["model"]
    assert any("not be fitted" in r for r in no_fmm["reasons"])

    # skewness=None (zero-variance): the MAM check is skipped, but it must not crash.
    #   Low OD -> CAM gate.
    skew_none_cam = recommend_age_model(od_rel=8.0, skewness=None, n=50, fmm=None)
    assert skew_none_cam["model"] == "CAM", skew_none_cam["model"]
    #   High OD + multimodal -> FMM (reached without skewness), reason states MAM was skipped.
    skew_none_fmm = recommend_age_model(
        od_rel=40.0, skewness=None, n=50, fmm={"delta_bic": 99.0, "best_k": 3, "sigmab": 0.15}
    )
    assert skew_none_fmm["model"] == "FMM", skew_none_fmm["model"]
    assert any("was skipped" in r for r in skew_none_fmm["reasons"])

    # delta_bic=None (a leftover from a failed FMM fit): treated as multimodality undetermined, no crash.
    dbic_none = recommend_age_model(
        od_rel=40.0, skewness=0.0, n=50, fmm={"delta_bic": None, "best_k": None, "sigmab": 0.15}
    )
    assert dbic_none["model"] == "CAM" and dbic_none["signals"]["multimodal"] is False

    # od_rel=None (OD couldn't be computed): the tree has no root, so raise explicitly.
    try:
        recommend_age_model(od_rel=None, skewness=0.0, n=50, fmm=None)
        assert False, "od_rel=None should raise ValueError"
    except ValueError:
        pass

    # Determinism: the same input twice -> the same result.
    a = recommend_age_model(od_rel=34.69, skewness=-0.037, n=62, fmm={"delta_bic": 95.5, "best_k": 3, "sigmab": 0.15})
    assert a["model"] == ca1["model"], "the same input produced a different model"

    # Boundary: when OD equals the threshold exactly, it's not CAM via the gate (only "<" qualifies). OD==20.0 -> passes the gate.
    edge_od = recommend_age_model(od_rel=OD_LOW_PCT, skewness=0.0, n=50, fmm={"delta_bic": 0.0, "best_k": 2, "sigmab": 0.15})
    assert edge_od["model"] == "CAM", "OD == threshold should fall back to CAM"
    assert edge_od["signals"]["od_rel"] == OD_LOW_PCT
    # When OD is just below the threshold, the gate itself gives CAM (the reason text should reflect the gate).
    below = recommend_age_model(od_rel=OD_LOW_PCT - 0.01, skewness=2.0, n=50, fmm={"delta_bic": 99.0, "best_k": 3, "sigmab": 0.15})
    assert below["model"] == "CAM" and "single population" in below["reasons"][0]

    print("model_recommend self-check OK")
