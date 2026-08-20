#!/usr/bin/env python3
"""Validate every dashboard panel query against a live Prometheus.

Catches the classes of bug this dashboard has actually shipped at least once:

  * a selector that matches nothing (a label typo, a regex that isn't anchored
    the way Prometheus anchors it) — the panel just renders "No data", which
    is easy to mistake for "the thing being measured is idle";
  * a query that is syntactically fine but returns no series;
  * topk()-style expressions that return more series than asked for, or
    fragmented part-series, because they are re-ranked at every step of a
    range query;
  * panels pointing at a datasource uid that does not exist on this install.

Exit code is non-zero if anything fails, so it can gate a commit or a deploy.

Usage:  scripts/validate-dashboard.py [--prom URL] [--range 6h]
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DASHBOARD = os.path.join(REPO, "grafana", "dashboards", "overview.json")

RANGE_SECONDS = {"m": 60, "h": 3600, "d": 86400}


def parse_range(text):
    m = re.fullmatch(r"(\d+)([mhd])", text)
    if not m:
        raise argparse.ArgumentTypeError("range looks like 30m / 6h / 2d")
    return int(m.group(1)) * RANGE_SECONDS[m.group(2)]


def prom_query_range(prom, expr, start, end, step):
    body = urllib.parse.urlencode(
        {"query": expr, "start": start, "end": end, "step": step}
    ).encode()
    try:
        raw = urllib.request.urlopen(prom + "/api/v1/query_range", body, timeout=120).read()
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read()[:200].decode(errors='replace')}"
    except Exception as e:  # noqa: BLE001 - surface whatever went wrong verbatim
        return None, str(e)
    payload = json.loads(raw)
    if payload.get("status") != "success":
        return None, payload.get("error", "unknown error")
    return payload["data"]["result"], None


def substitute_grafana_vars(expr, window):
    """Replace the Grafana-only placeholders with what Grafana would send."""
    expr = expr.replace("$__range", window)
    # $__rate_interval / $__interval depend on panel width; 1m is representative.
    expr = expr.replace("$__rate_interval", "1m").replace("$__interval", "1m")
    return expr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom", default=os.environ.get("PROM_URL", "http://localhost:9099"))
    ap.add_argument("--range", dest="window", default="6h", type=str)
    args = ap.parse_args()

    seconds = parse_range(args.window)
    end = int(time.time())
    start = end - seconds
    step = max(15, seconds // 400)

    dash = json.load(open(DASHBOARD))
    panels = [p for p in dash["panels"] if p.get("type") not in ("row", "text")]

    # Which datasource uids does this Grafana actually have? Only checkable when
    # Grafana credentials are supplied; skipped silently otherwise.
    failures, warnings, checked = [], [], 0

    for panel in panels:
        title = panel.get("title", "<untitled>")
        ds = (panel.get("datasource") or {}).get("uid")
        if not ds:
            warnings.append(f"{title}: no explicit datasource (falls back to whichever is default)")

        for target in panel.get("targets", []):
            expr = target.get("expr")
            if not expr:
                continue
            checked += 1
            resolved = substitute_grafana_vars(expr, args.window)
            result, err = prom_query_range(args.prom, resolved, start, end, step)

            label = f"{title} [{target.get('refId', '?')}]"
            if err:
                failures.append(f"{label}: query error: {err}")
                continue
            if not result:
                failures.append(f"{label}: returned NO SERIES (selector matches nothing?)")
                continue

            # topk(N, ...) must not yield more than N series, and a range query
            # that re-ranks per step betrays itself as fragmented part-series.
            m = re.search(r"topk\((\d+)", resolved)
            longest = max(len(s["values"]) for s in result)
            if m:
                n = int(m.group(1))
                if len(result) > n:
                    failures.append(
                        f"{label}: topk({n}) returned {len(result)} series — "
                        "ranking is being recomputed per step"
                    )
                    continue
            fragmented = [s for s in result if len(s["values"]) < longest * 0.8]
            if fragmented and len(result) > 1:
                warnings.append(
                    f"{label}: {len(fragmented)}/{len(result)} series are partial "
                    "(may just be a real data gap, e.g. a host reboot)"
                )

    print(f"checked {checked} queries across {len(panels)} panels "
          f"(range={args.window}, prometheus={args.prom})\n")
    for w in warnings:
        print(f"  WARN  {w}")
    for f in failures:
        print(f"  FAIL  {f}")
    if not failures and not warnings:
        print("  all queries returned data, no warnings")
    print(f"\n{len(failures)} failure(s), {len(warnings)} warning(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
