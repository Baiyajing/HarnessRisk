#!/usr/bin/env python3
"""Generate charts and tables for llm_judge results."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/matplotlib-lifecycle-llm-judge-analysis")

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


METRICS = [
    "attack_success_rate",
    "detection_score",
    "persistence_score",
    "utility_score",
]

METRIC_LABELS = {
    "attack_success_rate": "Attack Success Rate",
    "detection_score": "Detection",
    "persistence_score": "Persistence",
    "utility_score": "Utility",
}

CATEGORY_ORDER = ["setup", "skill", "daily", "memory", "action", "recovery"]
CASE_ID_RE = re.compile(r"(setup|skill|daily|memory|action|recovery)_\d+")


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def category_from_case(case_id: str) -> str:
    return case_id.rsplit("_", 1)[0]


def ordered_cases(df: pd.DataFrame) -> pd.DataFrame:
    category_rank = {category: idx for idx, category in enumerate(CATEGORY_ORDER)}
    out = df.copy()
    out["_category_rank"] = out["category"].map(category_rank).fillna(999)
    out["_case_num"] = out["case_id"].str.extract(r"_(\d+)").astype(int)
    return out.sort_values(["_category_rank", "_case_num", "case_id"]).drop(
        columns=["_category_rank", "_case_num"]
    )


def pct(value: float) -> str:
    return f"{value * 100:.1f}%"


def save_table_image(
    df: pd.DataFrame,
    path: Path,
    title: str,
    font_size: float = 8,
    row_height: float = 0.35,
    width: float = 14,
) -> None:
    height = max(3, 1.2 + len(df) * row_height)
    fig, ax = plt.subplots(figsize=(width, height))
    ax.axis("off")
    ax.set_title(title, fontsize=13, weight="bold", pad=12)
    table = ax.table(
        cellText=df.values,
        colLabels=df.columns,
        loc="center",
        cellLoc="center",
    )
    table.auto_set_font_size(False)
    table.set_fontsize(font_size)
    table.scale(1, 1.25)
    for (row, _col), cell in table.get_celld().items():
        if row == 0:
            cell.set_facecolor("#23395b")
            cell.set_text_props(color="white", weight="bold")
        elif row % 2 == 0:
            cell.set_facecolor("#f3f6fa")
        else:
            cell.set_facecolor("#ffffff")
        cell.set_edgecolor("#d4dbe6")
    fig.tight_layout()
    fig.savefig(path, dpi=220, bbox_inches="tight")
    plt.close(fig)


def load_cases(llm_judge_dir: Path) -> tuple[pd.DataFrame, list[dict]]:
    rows = []
    errors = []
    for path in sorted((llm_judge_dir / "results").glob("*.json")):
        data = read_json(path, {}) or {}
        case_id = data.get("case_id") or path.stem
        row = {
            "case_id": case_id,
            "category": category_from_case(case_id),
            "result_file": str(path),
        }
        if data.get("error"):
            errors.append({"case_id": case_id, "error": data.get("error"), "file": str(path)})
        for metric in METRICS:
            row[metric] = data.get(metric)
        row["confidence_utility_score"] = (data.get("confidence") or {}).get("utility_score")
        row["confidence_attack_success_rate"] = (data.get("confidence") or {}).get("attack_success_rate")
        row["confidence_persistence_score"] = (data.get("confidence") or {}).get("persistence_score")
        row["confidence_detection_score"] = (data.get("confidence") or {}).get("detection_score")
        row["ambiguous_or_missing_evidence_count"] = len(data.get("ambiguous_or_missing_evidence") or [])
        rows.append(row)
    df = pd.DataFrame(rows)
    if not df.empty:
        df = ordered_cases(df)
    return df, errors


def validate_binary(cases_df: pd.DataFrame) -> dict:
    missing = []
    non_binary = []
    incomplete_case_ids = set()
    for _, row in cases_df.iterrows():
        for metric in METRICS:
            value = row.get(metric)
            if pd.isna(value):
                missing.append({"case_id": row["case_id"], "metric": metric})
                incomplete_case_ids.add(row["case_id"])
            elif value not in (0, 1):
                non_binary.append(
                    {
                        "case_id": row["case_id"],
                        "metric": metric,
                        "value": value,
                        "type": type(value).__name__,
                    }
                )
                incomplete_case_ids.add(row["case_id"])
    complete_result_count = int(len(cases_df.dropna(subset=METRICS)))
    return {
        "result_count": int(len(cases_df)),
        "complete_result_count": complete_result_count,
        "incomplete_result_count": int(len(cases_df) - complete_result_count),
        "incomplete_case_ids": sorted(incomplete_case_ids),
        "missing_metric_count": len(missing),
        "non_binary_metric_count": len(non_binary),
        "all_metrics_binary": not missing and not non_binary,
        "missing_metrics": missing,
        "non_binary_metrics": non_binary,
    }


def build_category_metrics(cases_df: pd.DataFrame) -> pd.DataFrame:
    category_df = cases_df.groupby("category")[METRICS].mean()
    category_df["case_count"] = cases_df.groupby("category")["case_id"].count()
    category_df = category_df[["case_count", *METRICS]]
    ordered = [category for category in CATEGORY_ORDER if category in category_df.index]
    extras = [category for category in category_df.index if category not in ordered]
    return category_df.loc[ordered + extras]


def write_csvs(out_dir: Path, cases_df: pd.DataFrame, category_df: pd.DataFrame) -> None:
    cases_df[["case_id", "category", *METRICS]].to_csv(out_dir / "per_case_metrics.csv", index=False)
    category_df.reset_index().rename(columns={"index": "category"}).to_csv(
        out_dir / "category_metrics.csv", index=False
    )


def plot_overall(out_dir: Path, cases_df: pd.DataFrame) -> None:
    values = [cases_df[m].mean() for m in METRICS]
    colors = ["#c7493a", "#2f7d70", "#6d6e8a", "#d59b2d"]
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.bar([METRIC_LABELS[m] for m in METRICS], values, color=colors)
    ax.set_ylim(0, 1.08)
    ax.set_ylabel("Mean binary score")
    ax.set_title(f"LLM Judge Overall Scores Across {len(cases_df)} Cases", weight="bold")
    ax.grid(axis="y", alpha=0.25)
    for idx, value in enumerate(values):
        ax.text(idx, value + 0.015, f"{value:.2f}", ha="center", va="bottom", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_dir / "01_overall_metric_scores.png", dpi=220)
    plt.close(fig)


def plot_category_bars(out_dir: Path, category_df: pd.DataFrame) -> None:
    labels = category_df.index.tolist()
    x = np.arange(len(labels))
    width = 0.2
    colors = ["#c7493a", "#2f7d70", "#6d6e8a", "#d59b2d"]
    fig, ax = plt.subplots(figsize=(12, 6))
    for i, metric in enumerate(METRICS):
        ax.bar(
            x + (i - 1.5) * width,
            category_df[metric],
            width,
            label=METRIC_LABELS[metric],
            color=colors[i],
        )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylim(0, 1.05)
    ax.set_ylabel("Mean binary score")
    ax.set_title("LLM Judge Category-Level Average Scores", weight="bold")
    ax.grid(axis="y", alpha=0.25)
    ax.legend(ncols=2, frameon=False)
    fig.tight_layout()
    fig.savefig(out_dir / "02_category_metric_grouped_bars.png", dpi=220)
    plt.close(fig)


def plot_category_heatmap(out_dir: Path, category_df: pd.DataFrame) -> None:
    data = category_df[METRICS].to_numpy()
    fig, ax = plt.subplots(figsize=(9, 5))
    im = ax.imshow(data, cmap="RdYlGn", vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(np.arange(len(METRICS)))
    ax.set_xticklabels([METRIC_LABELS[m] for m in METRICS], rotation=25, ha="right")
    ax.set_yticks(np.arange(len(category_df.index)))
    ax.set_yticklabels(category_df.index)
    ax.set_title("LLM Judge Category-Level Metric Heatmap", weight="bold")
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            ax.text(j, i, f"{data[i, j]:.2f}", ha="center", va="center", fontsize=9)
    cbar = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    cbar.set_label("Mean binary score")
    fig.tight_layout()
    fig.savefig(out_dir / "03_category_metric_heatmap.png", dpi=220)
    plt.close(fig)


def plot_case_heatmap(out_dir: Path, cases_df: pd.DataFrame) -> None:
    data = cases_df[METRICS].to_numpy()
    fig, ax = plt.subplots(figsize=(10, 17))
    im = ax.imshow(data, cmap="RdYlGn", vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(np.arange(len(METRICS)))
    ax.set_xticklabels([METRIC_LABELS[m] for m in METRICS], rotation=25, ha="right")
    ax.set_yticks(np.arange(len(cases_df)))
    ax.set_yticklabels(cases_df["case_id"].str.replace("_", " ", regex=False), fontsize=7)
    ax.set_title(f"LLM Judge Per-Case Binary Scores ({len(cases_df)} Cases)", weight="bold")
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            ax.text(j, i, str(int(data[i, j])), ha="center", va="center", fontsize=7)
    boundaries = cases_df.groupby("category", sort=False).size().cumsum().tolist()[:-1]
    for boundary in boundaries:
        ax.axhline(boundary - 0.5, color="black", linewidth=0.8)
    cbar = fig.colorbar(im, ax=ax, fraction=0.035, pad=0.03)
    cbar.set_label("Binary score")
    fig.tight_layout()
    fig.savefig(out_dir / "04_per_case_metric_heatmap.png", dpi=240)
    plt.close(fig)


def plot_binary_distributions(out_dir: Path, cases_df: pd.DataFrame) -> None:
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharey=True)
    colors = ["#c7493a", "#2f7d70", "#6d6e8a", "#d59b2d"]
    for ax, metric, color in zip(axes.ravel(), METRICS, colors):
        counts = cases_df[metric].value_counts().reindex([0, 1], fill_value=0)
        ax.bar(["0", "1"], [counts[0], counts[1]], color=color, edgecolor="white")
        ax.set_title(METRIC_LABELS[metric])
        ax.set_xlabel("Binary score")
        ax.grid(axis="y", alpha=0.25)
        for idx, value in enumerate([counts[0], counts[1]]):
            ax.text(idx, value + 0.3, str(int(value)), ha="center", va="bottom", fontsize=9)
    axes[0, 0].set_ylabel("Case count")
    axes[1, 0].set_ylabel("Case count")
    fig.suptitle("LLM Judge Binary Score Distributions", weight="bold")
    fig.tight_layout()
    fig.savefig(out_dir / "05_metric_score_distributions.png", dpi=220)
    plt.close(fig)


def plot_utility_vs_attack(out_dir: Path, cases_df: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(8, 6))
    color_map = {
        "setup": "#3d5a80",
        "skill": "#2a9d8f",
        "daily": "#e9c46a",
        "memory": "#f4a261",
        "action": "#e76f51",
        "recovery": "#6d597a",
    }
    offsets = {
        "setup": (-0.025, -0.025),
        "skill": (0.025, -0.025),
        "daily": (-0.025, 0.025),
        "memory": (0.025, 0.025),
        "action": (0.0, -0.045),
        "recovery": (0.0, 0.045),
    }
    for category, group in cases_df.groupby("category", sort=False):
        dx, dy = offsets.get(category, (0.0, 0.0))
        ax.scatter(
            group["utility_score"] + dx,
            group["attack_success_rate"] + dy,
            label=category,
            s=75,
            alpha=0.85,
            color=color_map.get(category),
            edgecolor="white",
            linewidth=0.7,
        )
    ax.set_xlim(-0.12, 1.12)
    ax.set_ylim(-0.12, 1.12)
    ax.set_xticks([0, 1])
    ax.set_yticks([0, 1])
    ax.set_xlabel("Utility score")
    ax.set_ylabel("Attack success rate")
    ax.set_title("LLM Judge Utility vs. Attack Success", weight="bold")
    ax.grid(alpha=0.25)
    ax.legend(frameon=False, ncols=3)
    fig.tight_layout()
    fig.savefig(out_dir / "06_utility_vs_attack_success.png", dpi=220)
    plt.close(fig)


def plot_llm_vs_rule(out_dir: Path, llm_judge_dir: Path) -> pd.DataFrame:
    csv_path = llm_judge_dir / "llm_vs_rule_evaluator.csv"
    if not csv_path.exists():
        return pd.DataFrame()
    df = pd.read_csv(csv_path)
    rows = []
    for metric in METRICS:
        llm_col = f"llm_{metric}"
        rule_col = f"rule_{metric}"
        if llm_col not in df.columns or rule_col not in df.columns:
            continue
        valid = df[[llm_col, rule_col]].dropna()
        if valid.empty:
            continue
        rule_binary = (valid[rule_col].astype(float) >= 0.5).astype(int)
        llm_binary = valid[llm_col].astype(int)
        rows.append(
            {
                "metric": metric,
                "thresholded_agreement": float((llm_binary == rule_binary).mean()),
                "llm_mean": float(llm_binary.mean()),
                "rule_mean": float(valid[rule_col].astype(float).mean()),
            }
        )
    comp = pd.DataFrame(rows)
    if comp.empty:
        return comp
    x = np.arange(len(comp))
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.bar(x - 0.2, comp["llm_mean"], 0.2, label="LLM mean", color="#2f7d70")
    ax.bar(x, comp["rule_mean"], 0.2, label="Rule mean", color="#d59b2d")
    ax.bar(x + 0.2, comp["thresholded_agreement"], 0.2, label="Agreement", color="#6d6e8a")
    ax.set_xticks(x)
    ax.set_xticklabels([METRIC_LABELS[m] for m in comp["metric"]], rotation=20, ha="right")
    ax.set_ylim(0, 1.05)
    ax.set_ylabel("Score")
    ax.set_title("LLM Judge vs. Rule Evaluator", weight="bold")
    ax.grid(axis="y", alpha=0.25)
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig(out_dir / "07_llm_vs_rule_evaluator.png", dpi=220)
    plt.close(fig)
    comp.to_csv(out_dir / "llm_vs_rule_summary.csv", index=False)
    return comp


def build_table_images(out_dir: Path, cases_df: pd.DataFrame, category_df: pd.DataFrame) -> None:
    category_table = category_df.reset_index().rename(columns={"index": "category"}).copy()
    for metric in METRICS:
        category_table[metric] = category_table[metric].map(lambda x: f"{x:.4f}")
    save_table_image(
        category_table[["category", "case_count", *METRICS]],
        out_dir / "08_category_scores_table.png",
        "LLM Judge Category Scores",
        font_size=8,
        row_height=0.34,
        width=12,
    )
    case_table = cases_df[["case_id", *METRICS]].copy()
    for metric in METRICS:
        case_table[metric] = case_table[metric].map(lambda x: str(int(x)))
    save_table_image(
        case_table,
        out_dir / "09_per_case_scores_table.png",
        "LLM Judge Per-Case Binary Scores",
        font_size=6.2,
        row_height=0.22,
        width=12,
    )


def confidence_table(cases_df: pd.DataFrame, out_dir: Path) -> pd.DataFrame:
    cols = [f"confidence_{metric}" for metric in METRICS]
    rows = []
    for col in cols:
        metric = col.removeprefix("confidence_")
        counts = cases_df[col].fillna("missing").value_counts().to_dict()
        row = {"metric": metric}
        for key in ["high", "medium", "low", "missing"]:
            row[key] = int(counts.get(key, 0))
        rows.append(row)
    df = pd.DataFrame(rows)
    df.to_csv(out_dir / "confidence_counts.csv", index=False)
    return df


def write_report(
    out_dir: Path,
    llm_judge_dir: Path,
    cases_df: pd.DataFrame,
    category_df: pd.DataFrame,
    validation: dict,
    comparison_df: pd.DataFrame,
    errors: list[dict],
    confidence_df: pd.DataFrame,
) -> None:
    summary = {metric: float(cases_df[metric].mean()) for metric in METRICS}
    category_lines = []
    for category, row in category_df.iterrows():
        category_lines.append(
            f"| {category} | {int(row['case_count'])} | {row['attack_success_rate']:.4f} | "
            f"{row['detection_score']:.4f} | {row['persistence_score']:.4f} | {row['utility_score']:.4f} |"
        )
    binary_lines = []
    for metric in METRICS:
        counts = cases_df[metric].value_counts().reindex([0, 1], fill_value=0)
        binary_lines.append(
            f"| {METRIC_LABELS[metric]} | {int(counts[0])} | {int(counts[1])} | "
            f"{cases_df[metric].mean():.4f} |"
        )
    comparison_lines = []
    for row in comparison_df.itertuples(index=False):
        comparison_lines.append(
            f"| {METRIC_LABELS[row.metric]} | {row.llm_mean:.4f} | {row.rule_mean:.4f} | "
            f"{row.thresholded_agreement:.4f} |"
        )
    zero_detection = cases_df[cases_df["detection_score"] == 0]
    persistence_positive = cases_df[cases_df["persistence_score"] == 1]
    attack_positive = cases_df[cases_df["attack_success_rate"] == 1]
    utility_zero = cases_df[cases_df["utility_score"] == 0]
    confidence_lines = ["| Metric | High | Medium | Low | Missing |", "| --- | ---: | ---: | ---: | ---: |"]
    for row in confidence_df.itertuples(index=False):
        confidence_lines.append(
            f"| {row.metric} | {row.high} | {row.medium} | {row.low} | {row.missing} |"
        )
    report = f"""# LLM Judge 深度分析

分析对象：`{llm_judge_dir}`

## 1. 运行健康检查

- Result 文件数：{validation['result_count']}
- 完整 result 文件数：{validation['complete_result_count']}
- 被排除的不完整 result 文件数：{validation['incomplete_result_count']}
- 残留 error 文件数：{len(errors)}
- 缺失 metric 数：{validation['missing_metric_count']}
- 非二元 metric 数：{validation['non_binary_metric_count']}
- 四个 metric 是否全部为 0/1：{validation['all_metrics_binary']}

结论：本次图表统计使用 {validation['complete_result_count']} 个四项指标完整的 case。被排除的不完整 case：{', '.join(validation['incomplete_case_ids']) if validation['incomplete_case_ids'] else '无'}。

## 2. 总体结果

| Metric | #0 | #1 | Mean |
| --- | ---: | ---: | ---: |
{os.linesep.join(binary_lines)}

总体均值：

- Attack Success Rate: {summary['attack_success_rate']:.4f} ({pct(summary['attack_success_rate'])})
- Detection Score: {summary['detection_score']:.4f} ({pct(summary['detection_score'])})
- Persistence Score: {summary['persistence_score']:.4f} ({pct(summary['persistence_score'])})
- Utility Score: {summary['utility_score']:.4f} ({pct(summary['utility_score'])})

## 3. Category 分数

| Category | Cases | Attack Success Rate | Detection | Persistence | Utility |
| --- | ---: | ---: | ---: | ---: | ---: |
{os.linesep.join(category_lines)}

## 4. 与规则评分器对比

| Metric | LLM Mean | Rule Mean | Thresholded Agreement |
| --- | ---: | ---: | ---: |
{os.linesep.join(comparison_lines) if comparison_lines else '| N/A | N/A | N/A | N/A |'}

这里的 agreement 是把规则评分器分数按 `>=0.5` 二值化后与 LLM judge 的 0/1 结果比较。当前一致性最高的是 Utility 和 Attack，Persistence 最低，说明 LLM judge 与规则评分器在“是否构成持久化”上的判断差异最大。

## 5. 关键 case 集合

- Attack Success = 1：{len(attack_positive)} 个
- Detection = 0：{len(zero_detection)} 个，case: {', '.join(zero_detection['case_id'].tolist()) if len(zero_detection) else '无'}
- Persistence = 1：{len(persistence_positive)} 个，case: {', '.join(persistence_positive['case_id'].tolist()) if len(persistence_positive) else '无'}
- Utility = 0：{len(utility_zero)} 个，case: {', '.join(utility_zero['case_id'].tolist()) if len(utility_zero) else '无'}

## 6. 图表索引

- [01_overall_metric_scores.png](01_overall_metric_scores.png): LLM judge 四项总体均值。
- [02_category_metric_grouped_bars.png](02_category_metric_grouped_bars.png): category 维度分组柱状图。
- [03_category_metric_heatmap.png](03_category_metric_heatmap.png): category x metric 热力图。
- [04_per_case_metric_heatmap.png](04_per_case_metric_heatmap.png): {validation['complete_result_count']} case x 4 metric 二元热力图。
- [05_metric_score_distributions.png](05_metric_score_distributions.png): 四项 metric 的 0/1 分布。
- [06_utility_vs_attack_success.png](06_utility_vs_attack_success.png): Utility 与 Attack Success 二元散点图。
- [07_llm_vs_rule_evaluator.png](07_llm_vs_rule_evaluator.png): LLM judge 与规则评分器均值及一致性。
- [08_category_scores_table.png](08_category_scores_table.png): category 分数表。
- [09_per_case_scores_table.png](09_per_case_scores_table.png): per-case 二元分数表。

## 7. Confidence 分布

{os.linesep.join(confidence_lines)}
"""
    (out_dir / "analysis_report.md").write_text(report, encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Generate deep analysis artifacts for LLM judge results.")
    parser.add_argument("llm_judge_dir")
    parser.add_argument("--output-dir", default="")
    args = parser.parse_args(argv)

    llm_judge_dir = Path(args.llm_judge_dir).resolve()
    out_dir = Path(args.output_dir).resolve() if args.output_dir else llm_judge_dir / "deep_analysis"
    out_dir.mkdir(parents=True, exist_ok=True)

    cases_df, errors = load_cases(llm_judge_dir)
    if cases_df.empty:
        raise SystemExit(f"No LLM judge result JSON files found under {llm_judge_dir / 'results'}")
    validation = validate_binary(cases_df)
    (out_dir / "validation_summary.json").write_text(
        json.dumps(validation, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    category_df = build_category_metrics(cases_df)
    cases_df[["case_id", "category", *METRICS, "result_file"]].to_csv(
        out_dir / "all_per_case_metrics.csv", index=False
    )
    complete_cases_df = cases_df.dropna(subset=METRICS).copy()
    if complete_cases_df.empty:
        raise SystemExit("No complete LLM judge results with all metrics were found.")
    category_df = build_category_metrics(complete_cases_df)
    write_csvs(out_dir, complete_cases_df, category_df)
    plot_overall(out_dir, complete_cases_df)
    plot_category_bars(out_dir, category_df)
    plot_category_heatmap(out_dir, category_df)
    plot_case_heatmap(out_dir, complete_cases_df)
    plot_binary_distributions(out_dir, complete_cases_df)
    plot_utility_vs_attack(out_dir, complete_cases_df)
    comparison_df = plot_llm_vs_rule(out_dir, llm_judge_dir)
    build_table_images(out_dir, complete_cases_df, category_df)
    confidence_df = confidence_table(complete_cases_df, out_dir)
    write_report(
        out_dir,
        llm_judge_dir,
        complete_cases_df,
        category_df,
        validation,
        comparison_df,
        errors,
        confidence_df,
    )
    print(json.dumps({"output_dir": str(out_dir), "validation": validation}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
