"""Renders evidence/before_after.png from evidence/results.csv (log scale, before vs best after)."""
import csv, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = pathlib.Path(__file__).parent
rows = list(csv.DictReader(open(HERE / "evidence" / "results.csv")))
qs = sorted({r["query"] for r in rows})
before = [float(next(r for r in rows if r["query"] == q and r["phase"] == "before")["median_ms"]) for q in qs]
after = [min(float(r["median_ms"]) for r in rows if r["query"] == q and r["phase"] == "after") for q in qs]

BLUE, ORANGE, INK, MUTED, GRID = "#2a78d6", "#eb6834", "#1f1f1e", "#6b6a64", "#e4e3df"
fig, ax = plt.subplots(figsize=(10, 5.6), dpi=150)
y = range(len(qs))
h = 0.36
ax.barh([i - h / 2 - 0.01 for i in y], before, height=h, color=ORANGE, label="Before (baseline)")
ax.barh([i + h / 2 + 0.01 for i in y], after, height=h, color=BLUE, label="After (best variant)")
ax.set_xscale("log")
ax.set_yticks(list(y), qs, color=INK)
ax.invert_yaxis()
for i, (b, a) in enumerate(zip(before, after)):
    lab = ("≥ " if b >= 60000 else "") + f"{b / a:,.0f}× faster" + (" (baseline cancelled at 60 s)" if b >= 60000 else "")
    ax.text(max(b, a) * 1.6, i, lab, va="center", fontsize=9, color=INK)
ax.set_xlim(0.003, 1e7)
ax.set_xlabel("Median execution time (ms, log scale)", color=MUTED)
ax.set_title("PayHaven query workload: execution time before vs after optimisation", loc="left", color=INK, fontsize=12, pad=30)
ax.grid(axis="x", color=GRID, linewidth=0.8)
ax.set_axisbelow(True)
for s in ("top", "right", "left"):
    ax.spines[s].set_visible(False)
ax.spines["bottom"].set_color(GRID)
ax.tick_params(colors=MUTED, length=0)
ax.legend(loc="upper left", bbox_to_anchor=(0, 1.08), ncol=2, frameon=False, labelcolor=INK)
fig.tight_layout()
fig.savefig(HERE / "evidence" / "before_after.png")
