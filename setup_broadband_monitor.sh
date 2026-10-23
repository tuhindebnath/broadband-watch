#!/bin/bash
set -e

BASE="$HOME/broadband-monitor"
PY="$BASE/broadband_monitor.py"
VENV="$BASE/venv"
PLIST="$HOME/Library/LaunchAgents/com.broadbandmonitor.agent.plist"

echo "=============================================="
echo " Broadband Monitor - macOS installer"
echo "=============================================="

mkdir -p "$BASE"/{logs,reports,data}

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required."
    exit 1
fi

echo "[1/5] Creating Python environment..."
python3 -m venv "$VENV"

"$VENV/bin/python" -m pip install --upgrade pip >/dev/null
"$VENV/bin/python" -m pip install speedtest-cli >/dev/null

echo "[2/5] Creating monitoring application..."

cat > "$PY" <<'PYTHON'
#!/usr/bin/env python3

import argparse
import csv
import datetime as dt
import html
import json
import math
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

# ============================================================
# CONFIGURATION
# ============================================================

ROUTER_IP = "192.168.0.1"
WIFI_INTERFACE = "en0"

EXPECTED_DOWNLOAD = 100.0
EXPECTED_UPLOAD = 100.0

# Normal monitoring interval
CHECK_INTERVAL = 30

# Scheduled speed test
SPEEDTEST_INTERVAL = 30 * 60

# Public IP check
PUBLIC_IP_INTERVAL = 5 * 60

# Reports/checks
REPORT_CHECK_INTERVAL = 5 * 60

# Keep reports for 30 days
REPORT_RETENTION_DAYS = 30

# Keep raw monitoring data for 90 days
RAW_RETENTION_DAYS = 90

# Consider speed degraded below this percentage of plan
MIN_SPEED_PERCENT = 50

# Alert thresholds
HIGH_LATENCY_MS = 100
CRITICAL_LATENCY_MS = 200
SLOW_DNS_MS = 200

# Extra speed test cooldown
EXTRA_SPEED_COOLDOWN = 15 * 60

BASE = Path.home() / "broadband-monitor"
LOG_DIR = BASE / "logs"
REPORT_DIR = BASE / "reports"
DATA_DIR = BASE / "data"

CSV_FILE = DATA_DIR / "measurements.csv"
EVENT_FILE = LOG_DIR / "events.log"
PUBLIC_IP_FILE = DATA_DIR / "public_ip_history.csv"

REPORT_INDEX = REPORT_DIR / "index.html"

CSV_FIELDS = [
    "timestamp",
    "ssid",
    "wifi_rssi",
    "wifi_noise",
    "wifi_channel",
    "wifi_tx_rate",
    "router_latency_ms",
    "router_packet_loss_pct",
    "cloudflare_latency_ms",
    "cloudflare_packet_loss_pct",
    "google_latency_ms",
    "google_packet_loss_pct",
    "dns_cloudflare_ms",
    "dns_google_ms",
    "internet_reachable",
    "public_ip",
    "speedtest_ping_ms",
    "download_mbps",
    "upload_mbps",
    "speedtest_server",
    "status",
    "problem",
]

# ============================================================
# UTILITIES
# ============================================================

def ensure_dirs():
    for d in [BASE, LOG_DIR, REPORT_DIR, DATA_DIR]:
        d.mkdir(parents=True, exist_ok=True)


def now():
    return dt.datetime.now().astimezone()


def timestamp():
    return now().isoformat(timespec="seconds")


def log_event(message):
    ensure_dirs()
    line = f"{timestamp()} | {message}\n"
    with EVENT_FILE.open("a", encoding="utf-8") as f:
        f.write(line)


def safe_float(value):
    try:
        if value is None or value == "":
            return None
        return float(value)
    except Exception:
        return None


def fmt(value, digits=1, suffix=""):
    if value is None:
        return "N/A"
    return f"{value:.{digits}f}{suffix}"


def run_command(cmd, timeout=10):
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return p.stdout + p.stderr
    except Exception:
        return ""


# ============================================================
# PING
# ============================================================

def ping(host):
    output = run_command(
        ["ping", "-c", "3", "-W", "2000", host],
        timeout=10
    )

    loss = None
    latency = None

    m = re.search(r"(\d+(?:\.\d+)?)%\s*packet loss", output)
    if m:
        loss = float(m.group(1))

    m = re.search(
        r"(?:round-trip|round trip).*?=\s*"
        r"[\d.]+/([\d.]+)/[\d.]+/[\d.]+",
        output
    )

    if m:
        latency = float(m.group(1))

    return latency, loss


# ============================================================
# WIFI INFORMATION
# ============================================================

def wifi_info():
    result = {
        "ssid": "",
        "rssi": None,
        "noise": None,
        "channel": "",
        "tx_rate": None,
    }

    # Try system_profiler first
    output = run_command(
        ["system_profiler", "SPAirPortDataType"],
        timeout=15
    )

    # Current network section is normally below "Current Network Information"
    m = re.search(
        r"Current Network Information:\s*(.*?)(?:\n\s*\n|\Z)",
        output,
        re.S
    )

    section = m.group(1) if m else output

    # SSID
    m = re.search(r"^\s{8}(.+?):\s*$", section, re.M)
    if m:
        result["ssid"] = m.group(1).strip()

    # More reliable fallback from networksetup
    ns = run_command(
        ["networksetup", "-getairportnetwork", WIFI_INTERFACE],
        timeout=5
    )

    m = re.search(r"Current Wi-Fi Network:\s*(.+)", ns)
    if m:
        result["ssid"] = m.group(1).strip()

    # RSSI
    m = re.search(r"Signal / Noise:\s*(-?\d+)\s*/\s*(-?\d+)", output)
    if m:
        result["rssi"] = float(m.group(1))
        result["noise"] = float(m.group(2))

    # Alternate formats
    if result["rssi"] is None:
        m = re.search(r"Signal Strength:\s*(-?\d+)", output)
        if m:
            result["rssi"] = float(m.group(1))

    # Tx rate
    m = re.search(r"Transmit Rate:\s*([\d.]+)", output)
    if m:
        result["tx_rate"] = float(m.group(1))

    # Channel
    m = re.search(r"Channel:\s*([0-9]+(?:\s*,\s*[A-Za-z0-9]+)?)", output)
    if m:
        result["channel"] = m.group(1).strip()

    return result


# ============================================================
# DNS TEST
# ============================================================

def dns_test(server):
    """
    Lightweight DNS UDP query.
    Avoids depending on nslookup/dig.
    """

    try:
        import struct
        import random

        transaction_id = random.randint(0, 65535)

        qname = b""
        for part in "www.google.com".split("."):
            encoded = part.encode()
            qname += bytes([len(encoded)]) + encoded
        qname += b"\x00"

        header = struct.pack(
            "!HHHHHH",
            transaction_id,
            0x0100,
            1,
            0,
            0,
            0
        )

        question = qname + struct.pack("!HH", 1, 1)

        packet = header + question

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2)

        start = time.monotonic()
        sock.sendto(packet, (server, 53))
        data, _ = sock.recvfrom(4096)
        elapsed = (time.monotonic() - start) * 1000

        sock.close()

        if len(data) >= 12:
            return elapsed

    except Exception:
        pass

    return None


# ============================================================
# INTERNET CONNECTIVITY
# ============================================================

def internet_test():
    start = time.monotonic()

    try:
        sock = socket.create_connection(
            ("www.google.com", 443),
            timeout=5
        )
        sock.close()

        return True, (time.monotonic() - start) * 1000

    except Exception:
        return False, None


# ============================================================
# PUBLIC IP
# ============================================================

def get_public_ip():
    try:
        req = urllib.request.Request(
            "https://api.ipify.org",
            headers={"User-Agent": "BroadbandMonitor/1.0"}
        )

        with urllib.request.urlopen(req, timeout=5) as r:
            return r.read().decode().strip()

    except Exception:
        return ""


def record_public_ip(ip):
    if not ip:
        return

    exists = PUBLIC_IP_FILE.exists()

    with PUBLIC_IP_FILE.open("a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)

        if not exists:
            writer.writerow(["timestamp", "public_ip"])

        writer.writerow([timestamp(), ip])


# ============================================================
# SPEED TEST
# ============================================================

def speed_test():
    """
    Uses speedtest-cli.
    """

    try:
        import speedtest

        st = speedtest.Speedtest()
        st.get_best_server()

        ping_ms = st.results.ping
        server = ""

        try:
            server = (
                f"{st.results.server.get('sponsor', '')} "
                f"{st.results.server.get('name', '')}"
            ).strip()
        except Exception:
            pass

        download = st.download() / 1_000_000
        upload = st.upload() / 1_000_000

        return {
            "ping": ping_ms,
            "download": download,
            "upload": upload,
            "server": server,
        }

    except Exception as e:
        log_event(f"SPEEDTEST_ERROR | {e}")
        return None


# ============================================================
# ANALYSIS
# ============================================================

def analyze(data):
    problems = []

    router_latency = data["router_latency_ms"]
    router_loss = data["router_packet_loss_pct"]
    rssi = data["wifi_rssi"]

    cf_latency = data["cloudflare_latency_ms"]
    cf_loss = data["cloudflare_packet_loss_pct"]

    dns_cf = data["dns_cloudflare_ms"]

    download = data["download_mbps"]
    upload = data["upload_mbps"]

    reachable = data["internet_reachable"]

    if router_loss is not None and router_loss > 0:
        problems.append("router_packet_loss")

    if router_latency is not None and router_latency > HIGH_LATENCY_MS:
        problems.append("router_high_latency")

    if rssi is not None and rssi < -75:
        problems.append("weak_wifi_signal")

    if not reachable:
        problems.append("internet_unreachable")

    if cf_loss is not None and cf_loss > 0:
        problems.append("internet_packet_loss")

    if cf_latency is not None and cf_latency > CRITICAL_LATENCY_MS:
        problems.append("internet_high_latency")

    if dns_cf is not None and dns_cf > SLOW_DNS_MS:
        problems.append("slow_dns")

    if download is not None:
        if download < EXPECTED_DOWNLOAD * MIN_SPEED_PERCENT / 100:
            problems.append("slow_download")

    if upload is not None:
        if upload < EXPECTED_UPLOAD * MIN_SPEED_PERCENT / 100:
            problems.append("slow_upload")

    # Classification
    if not problems:
        status = "OK"

    elif (
        "router_packet_loss" in problems
        or "router_high_latency" in problems
        or "weak_wifi_signal" in problems
    ):
        status = "LOCAL_WIFI_OR_ROUTER"

    elif (
        "internet_packet_loss" in problems
        or "internet_high_latency" in problems
        or "slow_download" in problems
        or "slow_upload" in problems
    ):
        status = "BEYOND_ROUTER"

    elif "slow_dns" in problems:
        status = "DNS"

    else:
        status = "DEGRADED"

    return status, ",".join(problems)


# ============================================================
# CSV
# ============================================================

def append_measurement(row):
    exists = CSV_FILE.exists()

    with CSV_FILE.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=CSV_FIELDS
        )

        if not exists:
            writer.writeheader()

        writer.writerow(row)


# ============================================================
# DATA RETENTION
# ============================================================

def cleanup_raw_data():
    """
    measurements.csv is retained but old rows are removed.
    """

    if not CSV_FILE.exists():
        return

    cutoff = now() - dt.timedelta(days=RAW_RETENTION_DAYS)

    tmp = CSV_FILE.with_suffix(".tmp")

    try:
        with CSV_FILE.open("r", encoding="utf-8") as src:
            reader = csv.DictReader(src)

            with tmp.open("w", newline="", encoding="utf-8") as dst:
                writer = csv.DictWriter(
                    dst,
                    fieldnames=CSV_FIELDS
                )
                writer.writeheader()

                for row in reader:
                    try:
                        ts = dt.datetime.fromisoformat(row["timestamp"])
                        if ts >= cutoff:
                            writer.writerow(row)
                    except Exception:
                        continue

        tmp.replace(CSV_FILE)

    except Exception:
        if tmp.exists():
            tmp.unlink()


def cleanup_reports():
    cutoff = now().date() - dt.timedelta(days=REPORT_RETENTION_DAYS)

    for f in REPORT_DIR.glob("*.html"):
        if f.name == "index.html":
            continue

        try:
            day = dt.date.fromisoformat(f.stem)

            if day < cutoff:
                f.unlink()

        except Exception:
            pass


# ============================================================
# DAILY DATA
# ============================================================

def load_day(day):
    rows = []

    if not CSV_FILE.exists():
        return rows

    with CSV_FILE.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        for row in reader:
            try:
                ts = dt.datetime.fromisoformat(row["timestamp"])

                if ts.date() == day:
                    rows.append(row)

            except Exception:
                continue

    return rows


def values(rows, field):
    result = []

    for r in rows:
        v = safe_float(r.get(field))

        if v is not None:
            result.append(v)

    return result


# ============================================================
# SVG GRAPH
# ============================================================

def svg_graph(rows, field, title, unit="", width=1000, height=300):
    data = []

    for r in rows:
        y = safe_float(r.get(field))

        if y is None:
            continue

        try:
            ts = dt.datetime.fromisoformat(r["timestamp"])
            x = ts.hour * 3600 + ts.minute * 60 + ts.second
        except Exception:
            x = len(data)

        data.append((x, y))

    if not data:
        return f"""
        <div class="graph">
            <h3>{html.escape(title)}</h3>
            <p>No data available.</p>
        </div>
        """

    min_y = min(y for _, y in data)
    max_y = max(y for _, y in data)

    if math.isclose(min_y, max_y):
        pad = max(abs(min_y) * 0.1, 1)
        min_y -= pad
        max_y += pad

    left = 55
    right = 20
    top = 35
    bottom = 35

    plot_w = width - left - right
    plot_h = height - top - bottom

    def px(x):
        return left + (x / 86400) * plot_w

    def py(y):
        return top + (max_y - y) / (max_y - min_y) * plot_h

    points = " ".join(
        f"{px(x):.1f},{py(y):.1f}"
        for x, y in data
    )

    return f"""
    <div class="graph">
      <h3>{html.escape(title)}</h3>

      <svg viewBox="0 0 {width} {height}"
           width="100%"
           role="img"
           aria-label="{html.escape(title)}">

        <line x1="{left}" y1="{top}"
              x2="{left}" y2="{height-bottom}"
              class="axis"/>

        <line x1="{left}" y1="{height-bottom}"
              x2="{width-right}" y2="{height-bottom}"
              class="axis"/>

        <polyline
          points="{points}"
          class="line"
          fill="none"/>

        <text x="{left}" y="20" class="label">
          {html.escape(f"{max_y:.1f} {unit}")}
        </text>

        <text x="{left}" y="{height-8}" class="label">
          {html.escape(f"{min_y:.1f} {unit}")}
        </text>

      </svg>
    </div>
    """


# ============================================================
# REPORT GENERATION
# ============================================================

def generate_report(day):
    rows = load_day(day)

    if not rows:
        return False

    def avg(field):
        v = values(rows, field)
        return statistics.mean(v) if v else None

    def minimum(field):
        v = values(rows, field)
        return min(v) if v else None

    def maximum(field):
        v = values(rows, field)
        return max(v) if v else None

    total = len(rows)

    reachable_count = sum(
        1 for r in rows
        if r.get("internet_reachable") == "True"
    )

    availability = (
        reachable_count / total * 100
        if total
        else 0
    )

    statuses = {}

    for r in rows:
        s = r.get("status", "UNKNOWN")
        statuses[s] = statuses.get(s, 0) + 1

    problem_rows = [
        r for r in rows
        if r.get("status") != "OK"
    ]

    speed_rows = [
        r for r in rows
        if safe_float(r.get("download_mbps")) is not None
    ]

    report_name = f"{day.isoformat()}.html"
    report_path = REPORT_DIR / report_name

    status_html = ""

    for status, count in sorted(
        statuses.items(),
        key=lambda x: (-x[1], x[0])
    ):
        status_html += (
            f"<tr><td>{html.escape(status)}</td>"
            f"<td>{count}</td>"
            f"<td>{count / total * 100:.1f}%</td></tr>"
        )

    if problem_rows:
        problem_html = "<table><tr><th>Time</th><th>Status</th><th>Problem</th></tr>"

        for r in problem_rows[:200]:
            problem_html += (
                "<tr>"
                f"<td>{html.escape(r.get('timestamp',''))}</td>"
                f"<td>{html.escape(r.get('status',''))}</td>"
                f"<td>{html.escape(r.get('problem',''))}</td>"
                "</tr>"
            )

        problem_html += "</table>"

    else:
        problem_html = "<p>No degraded samples were recorded.</p>"

    classification = []

    local_count = statuses.get("LOCAL_WIFI_OR_ROUTER", 0)
    beyond_count = statuses.get("BEYOND_ROUTER", 0)
    dns_count = statuses.get("DNS", 0)

    if local_count:
        classification.append(
            f"{local_count} samples showed local Wi-Fi/router indicators."
        )

    if beyond_count:
        classification.append(
            f"{beyond_count} samples showed degradation beyond the router."
        )

    if dns_count:
        classification.append(
            f"{dns_count} samples showed DNS-related slowness."
        )

    if not classification:
        classification.append(
            "No significant degradation indicators were detected."
        )

    classification_html = "".join(
        f"<li>{html.escape(x)}</li>"
        for x in classification
    )

    graphs = ""

    graphs += svg_graph(
        rows,
        "download_mbps",
        "Download speed",
        "Mbps"
    )

    graphs += svg_graph(
        rows,
        "upload_mbps",
        "Upload speed",
        "Mbps"
    )

    graphs += svg_graph(
        rows,
        "cloudflare_latency_ms",
        "Internet latency",
        "ms"
    )

    graphs += svg_graph(
        rows,
        "cloudflare_packet_loss_pct",
        "Internet packet loss",
        "%"
    )

    graphs += svg_graph(
        rows,
        "dns_cloudflare_ms",
        "DNS response time",
        "ms"
    )

    graphs += svg_graph(
        rows,
        "wifi_rssi",
        "Wi-Fi RSSI",
        "dBm"
    )

    speed_test_count = len(speed_rows)

    html_doc = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">

<title>Broadband Report - {day}</title>

<style>

body {{
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;
    margin:0;
    background:#f5f5f7;
    color:#222;
}}

.container {{
    max-width:1200px;
    margin:auto;
    padding:24px;
}}

h1 {{
    margin-bottom:4px;
}}

.subtitle {{
    color:#666;
}}

.cards {{
    display:grid;
    grid-template-columns:repeat(auto-fit,minmax(180px,1fr));
    gap:12px;
    margin:20px 0;
}}

.card {{
    background:white;
    padding:18px;
    border-radius:12px;
    box-shadow:0 1px 5px rgba(0,0,0,.08);
}}

.card .value {{
    font-size:24px;
    font-weight:700;
}}

.card .label {{
    color:#666;
    font-size:13px;
}}

section {{
    background:white;
    padding:20px;
    border-radius:12px;
    margin:20px 0;
}}

table {{
    width:100%;
    border-collapse:collapse;
}}

th,td {{
    text-align:left;
    padding:8px;
    border-bottom:1px solid #eee;
}}

.graph {{
    margin:20px 0;
}}

.graph svg {{
    background:#fafafa;
    border-radius:8px;
}}

.line {{
    stroke:currentColor;
    stroke-width:2;
}}

.axis {{
    stroke:#999;
    stroke-width:1;
}}

.label {{
    font-size:12px;
    fill:#666;
}}

.note {{
    background:#fff8dc;
    border-left:4px solid #d8a600;
    padding:12px;
}}

</style>
</head>

<body>

<div class="container">

<h1>Broadband Daily Report</h1>
<div class="subtitle">
{day} · Router {ROUTER_IP} · Wi-Fi {WIFI_INTERFACE} · Plan {EXPECTED_DOWNLOAD:.0f}/{EXPECTED_UPLOAD:.0f} Mbps
</div>

<div class="cards">

<div class="card">
<div class="value">{availability:.2f}%</div>
<div class="label">Sample reachability</div>
</div>

<div class="card">
<div class="value">{fmt(avg("download_mbps"),1," Mbps")}</div>
<div class="label">Average download</div>
</div>

<div class="card">
<div class="value">{fmt(minimum("download_mbps"),1," Mbps")}</div>
<div class="label">Minimum download</div>
</div>

<div class="card">
<div class="value">{fmt(avg("upload_mbps"),1," Mbps")}</div>
<div class="label">Average upload</div>
</div>

<div class="card">
<div class="value">{fmt(avg("cloudflare_latency_ms"),1," ms")}</div>
<div class="label">Average Internet latency</div>
</div>

<div class="card">
<div class="value">{fmt(maximum("cloudflare_latency_ms"),1," ms")}</div>
<div class="label">Maximum Internet latency</div>
</div>

<div class="card">
<div class="value">{fmt(avg("wifi_rssi"),1," dBm")}</div>
<div class="label">Average Wi-Fi RSSI</div>
</div>

<div class="card">
<div class="value">{speed_test_count}</div>
<div class="label">Speed tests</div>
</div>

</div>

<section>
<h2>Interpretation</h2>

<div class="note">
These measurements are evidence of observed network conditions from this Mac.
They do not independently prove whether the ISP, router, Wi-Fi environment,
or another part of the network is responsible.
</div>

<ul>
{classification_html}
</ul>

<p>
<strong>Useful diagnostic:</strong>
If router latency/loss and Wi-Fi signal remain healthy while Internet
latency/loss increases or speed falls, the measurements are consistent with
degradation beyond the local router.
If router latency/loss or RSSI deteriorates at the same time, local Wi-Fi/router
conditions should be investigated.
</p>

</section>

<section>
<h2>Status distribution</h2>

<table>
<tr>
<th>Status</th>
<th>Samples</th>
<th>Percentage</th>
</tr>
{status_html}
</table>

</section>

<section>
<h2>Graphs</h2>
{graphs}
</section>

<section>
<h2>Problem samples</h2>

{problem_html}

</section>

<section>
<h2>Monitoring configuration</h2>

<table>

<tr>
<td>Router</td>
<td>{ROUTER_IP}</td>
</tr>

<tr>
<td>Wi-Fi interface</td>
<td>{WIFI_INTERFACE}</td>
</tr>

<tr>
<td>Expected download</td>
<td>{EXPECTED_DOWNLOAD} Mbps</td>
</tr>

<tr>
<td>Expected upload</td>
<td>{EXPECTED_UPLOAD} Mbps</td>
</tr>

<tr>
<td>Monitoring interval</td>
<td>{CHECK_INTERVAL} seconds</td>
</tr>

<tr>
<td>Scheduled speed test</td>
<td>Every {SPEEDTEST_INTERVAL // 60} minutes</td>
</tr>

<tr>
<td>Slow speed threshold</td>
<td>{MIN_SPEED_PERCENT}% of plan</td>
</tr>

<tr>
<td>Report retention</td>
<td>{REPORT_RETENTION_DAYS} days</td>
</tr>

</table>

</section>

</div>
</body>
</html>
"""

    report_path.write_text(
        html_doc,
        encoding="utf-8"
    )

    return True


# ============================================================
# REPORT INDEX
# ============================================================

def generate_index():
    reports = []

    for f in REPORT_DIR.glob("*.html"):
        if f.name == "index.html":
            continue

        try:
            day = dt.date.fromisoformat(f.stem)
            reports.append((day, f.name))
        except Exception:
            continue

    reports.sort(reverse=True)

    rows = ""

    for day, filename in reports[:REPORT_RETENTION_DAYS]:
        rows += (
            f"<tr>"
            f"<td>{day}</td>"
            f"<td><a href='{html.escape(filename)}'>Open report</a></td>"
            f"</tr>"
        )

    document = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">

<title>Broadband Monitor Reports</title>

<style>
body {{
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;
    background:#f5f5f7;
    margin:0;
}}

.container {{
    max-width:900px;
    margin:auto;
    padding:30px;
}}

section {{
    background:white;
    padding:20px;
    border-radius:12px;
}}

table {{
    width:100%;
    border-collapse:collapse;
}}

th,td {{
    padding:10px;
    border-bottom:1px solid #eee;
    text-align:left;
}}
</style>

</head>

<body>

<div class="container">

<section>

<h1>Broadband Monitor</h1>

<p>
Daily broadband diagnostic reports.
Latest {REPORT_RETENTION_DAYS} reports are retained.
</p>

<table>
<tr>
<th>Date</th>
<th>Report</th>
</tr>

{rows}

</table>

</section>

</div>

</body>
</html>
"""

    REPORT_INDEX.write_text(
        document,
        encoding="utf-8"
    )


# ============================================================
# CATCH-UP REPORTS
# ============================================================

def generate_missing_reports():
    """
    If the Mac was asleep/off around midnight,
    generate reports for recent days when data exists.
    """

    today = now().date()

    for i in range(REPORT_RETENTION_DAYS):
        day = today - dt.timedelta(days=i)

        rows = load_day(day)

        if not rows:
            continue

        path = REPORT_DIR / f"{day.isoformat()}.html"

        if not path.exists():
            try:
                generate_report(day)
            except Exception as e:
                log_event(
                    f"REPORT_ERROR | {day} | {e}"
                )

    generate_index()
    cleanup_reports()


# ============================================================
# MONITOR
# ============================================================

def run_monitor():

    ensure_dirs()

    log_event("MONITOR_STARTED")

    last_speed_test = 0
    last_extra_speed_test = 0
    last_public_ip = 0
    last_report_check = 0

    current_public_ip = ""

    while True:

        cycle_start = time.monotonic()

        try:

            wifi = wifi_info()

            router_latency, router_loss = ping(ROUTER_IP)

            cf_latency, cf_loss = ping("1.1.1.1")

            google_latency, google_loss = ping("8.8.8.8")

            dns_cf = dns_test("1.1.1.1")

            dns_google = dns_test("8.8.8.8")

            reachable, internet_connection_time = internet_test()

            current_time = time.monotonic()

            # Public IP
            if current_time - last_public_ip >= PUBLIC_IP_INTERVAL:

                ip = get_public_ip()

                if ip:

                    if current_public_ip and ip != current_public_ip:
                        log_event(
                            f"PUBLIC_IP_CHANGED | "
                            f"{current_public_ip} -> {ip}"
                        )

                    current_public_ip = ip
                    record_public_ip(ip)

                last_public_ip = current_time

            download = None
            upload = None
            speed_ping = None
            speed_server = ""

            # Scheduled speed test
            do_speed = (
                current_time - last_speed_test
                >= SPEEDTEST_INTERVAL
            )

            # Immediate test if serious degradation
            degradation = (
                (cf_loss is not None and cf_loss > 0)
                or (
                    cf_latency is not None
                    and cf_latency > CRITICAL_LATENCY_MS
                )
                or not reachable
            )

            do_extra_speed = (
                degradation
                and
                current_time - last_extra_speed_test
                >= EXTRA_SPEED_COOLDOWN
            )

            if do_speed or do_extra_speed:

                result = speed_test()

                if result:

                    speed_ping = result["ping"]
                    download = result["download"]
                    upload = result["upload"]
                    speed_server = result["server"]

                    last_speed_test = current_time

                    if do_extra_speed:
                        last_extra_speed_test = current_time

                    log_event(
                        f"SPEEDTEST | "
                        f"download={download:.2f} Mbps | "
                        f"upload={upload:.2f} Mbps | "
                        f"ping={speed_ping:.2f} ms | "
                        f"server={speed_server}"
                    )

            row = {
                "timestamp": timestamp(),

                "ssid": wifi["ssid"],
                "wifi_rssi": wifi["rssi"],
                "wifi_noise": wifi["noise"],
                "wifi_channel": wifi["channel"],
                "wifi_tx_rate": wifi["tx_rate"],

                "router_latency_ms": router_latency,
                "router_packet_loss_pct": router_loss,

                "cloudflare_latency_ms": cf_latency,
                "cloudflare_packet_loss_pct": cf_loss,

                "google_latency_ms": google_latency,
                "google_packet_loss_pct": google_loss,

                "dns_cloudflare_ms": dns_cf,
                "dns_google_ms": dns_google,

                "internet_reachable": reachable,

                "public_ip": current_public_ip,

                "speedtest_ping_ms": speed_ping,
                "download_mbps": download,
                "upload_mbps": upload,
                "speedtest_server": speed_server,

                "status": "",
                "problem": "",
            }

            status, problem = analyze(row)

            row["status"] = status
            row["problem"] = problem

            append_measurement(row)

            if status != "OK":

                log_event(
                    f"DEGRADED | "
                    f"status={status} | "
                    f"problem={problem} | "
                    f"router={router_latency}ms/{router_loss}% | "
                    f"internet={cf_latency}ms/{cf_loss}% | "
                    f"rssi={wifi['rssi']}"
                )

            # Generate reports periodically
            current_time = time.monotonic()

            if current_time - last_report_check >= REPORT_CHECK_INTERVAL:

                generate_missing_reports()

                # Also keep today's report current
                try:
                    generate_report(now().date())
                    generate_index()
                except Exception as e:
                    log_event(
                        f"REPORT_ERROR | {e}"
                    )

                cleanup_raw_data()

                last_report_check = current_time

        except Exception as e:

            log_event(
                f"MONITOR_ERROR | {type(e).__name__}: {e}"
            )

        elapsed = time.monotonic() - cycle_start

        sleep_time = max(
            1,
            CHECK_INTERVAL - elapsed
        )

        time.sleep(sleep_time)


# ============================================================
# INSTALL / UNINSTALL
# ============================================================

def install_launchd():

    ensure_dirs()

    launch_agents = Path.home() / "Library" / "LaunchAgents"

    launch_agents.mkdir(
        parents=True,
        exist_ok=True
    )

    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC
 "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>

    <key>Label</key>
    <string>com.broadbandmonitor.agent</string>

    <key>ProgramArguments</key>
    <array>
        <string>{BASE}/venv/bin/python</string>
        <string>{BASE}/broadband_monitor.py</string>
        <string>--run</string>
    </array>

    <key>WorkingDirectory</key>
    <string>{BASE}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ProcessType</key>
    <string>Background</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>{LOG_DIR}/launchd.stdout.log</string>

    <key>StandardErrorPath</key>
    <string>{LOG_DIR}/launchd.stderr.log</string>

</dict>
</plist>
"""

    Path(plist_path()).write_text(
        plist,
        encoding="utf-8"
    )

    uid = os.getuid()

    subprocess.run(
        [
            "launchctl",
            "bootout",
            f"gui/{uid}/com.broadbandmonitor.agent"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    subprocess.run(
        [
            "launchctl",
            "bootstrap",
            f"gui/{uid}",
            str(plist_path())
        ],
        check=True
    )

    subprocess.run(
        [
            "launchctl",
            "kickstart",
            "-k",
            f"gui/{uid}/com.broadbandmonitor.agent"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    print("")
    print("Broadband monitor installed.")
    print("")
    print(f"Base directory: {BASE}")
    print(f"Reports:        {REPORT_DIR}")
    print(f"Raw data:       {DATA_DIR}")
    print(f"Events:         {EVENT_FILE}")
    print("")


def plist_path():
    return (
        Path.home()
        / "Library"
        / "LaunchAgents"
        / "com.broadbandmonitor.agent.plist"
    )


def uninstall_launchd():

    uid = os.getuid()

    subprocess.run(
        [
            "launchctl",
            "bootout",
            f"gui/{uid}/com.broadbandmonitor.agent"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    p = plist_path()

    if p.exists():
        p.unlink()

    print("Broadband monitor service removed.")


# ============================================================
# MAIN
# ============================================================

def main():

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--run",
        action="store_true"
    )

    parser.add_argument(
        "--install",
        action="store_true"
    )

    parser.add_argument(
        "--uninstall",
        action="store_true"
    )

    parser.add_argument(
        "--report",
        nargs="?",
        const="yesterday"
    )

    args = parser.parse_args()

    ensure_dirs()

    if args.install:
        install_launchd()
        return

    if args.uninstall:
        uninstall_launchd()
        return

    if args.report:

        if args.report == "yesterday":
            day = now().date() - dt.timedelta(days=1)
        else:
            day = dt.date.fromisoformat(args.report)

        if generate_report(day):
            generate_index()
            print(
                REPORT_DIR / f"{day.isoformat()}.html"
            )
        else:
            print(
                f"No monitoring data found for {day}"
            )

        return

    if args.run:
        run_monitor()
        return

    parser.print_help()


if __name__ == "__main__":
    main()

PYTHON

chmod +x "$PY"

echo "[3/5] Installing launchd service..."

"$VENV/bin/python" "$PY" --install

echo "[4/5] Creating initial report index..."

"$VENV/bin/python" "$PY" --report yesterday >/dev/null 2>&1 || true

echo "[5/5] Verifying service..."

sleep 3

    if launchctl print "gui/$(id -u)/com.broadbandmonitor.agent" >/dev/null 2>&1; then
    echo ""
    echo "=============================================="
    echo " INSTALLATION SUCCESSFUL"
    echo "=============================================="
    echo ""
    echo "Monitor directory:"
    echo "  $BASE"
    echo ""
    echo "Reports:"
    echo "  $BASE/reports/index.html"
    echo ""
    echo "Raw measurements:"
    echo "  $BASE/data/measurements.csv"
    echo ""
    echo "Event log:"
    echo "  $BASE/logs/events.log"
    echo ""
    echo "Service:"
    echo "  com.broadbandmonitor.agent"
    echo ""
    echo "Open reports with:"
    echo "  open $BASE/reports/index.html"
    echo ""
    echo "Watch live events with:"
    echo "  tail -f $BASE/logs/events.log"
    echo ""
else
    echo ""
    echo "WARNING: launchd service could not be verified."
    echo ""
    echo "Check:"
    echo "  launchctl print gui/$(id -u)/com.broadbandmonitor.agent"
    echo ""
    exit 1
fi
