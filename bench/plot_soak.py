"""Plot the Linux soak's recorded RSS/PSS using matplotlib (a reporting tool)."""

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def plot(source: Path, output: Path) -> None:
    result = json.loads(source.read_text())
    samples = result["samples"]
    if not samples:
        raise ValueError("The soak result contains no memory samples")
    series = {}
    for sample in samples:
        for process in [sample["master"], *sample["workers"]]:
            if process.get("missing"):
                continue
            series.setdefault(process["pid"], []).append(
                (
                    sample["elapsed_seconds"] / 60,
                    process["rss_kb"] / 1024,
                    process["pss_kb"] / 1024,
                )
            )
    master_pid = samples[0]["master"]["pid"]
    figure, axes = plt.subplots(2, 1, sharex=True, figsize=(10, 7), layout="constrained")
    for pid, rows in series.items():
        minutes, rss, pss = zip(*rows)
        label = f"{'Master' if pid == master_pid else 'Worker'} {pid}"
        style = "--" if pid == master_pid else "-"
        axes[0].plot(minutes, rss, style, label=label, linewidth=1.4)
        axes[1].plot(minutes, pss, style, label=label, linewidth=1.4)
    axes[0].set_ylabel("RSS (MiB)")
    axes[1].set_ylabel("PSS (MiB)")
    axes[1].set_xlabel("Elapsed time (minutes)")
    for axis in axes:
        axis.grid(alpha=0.25)
        axis.legend(loc="upper left", ncols=3, fontsize=8)
    totals = result["totals"]
    figure.suptitle(
        f"gritz-native soak: {result['elapsed_seconds'] / 60:.1f} minutes, "
        f"{totals['requests']:,} RPCs, {totals['errors']} errors"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output)
    plt.close(figure)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    plot(args.result, args.output or args.result.with_suffix(".svg"))
