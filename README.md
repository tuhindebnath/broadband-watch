# Broadband Watch

**A local-first broadband monitor for macOS.** Track the quality of your home connection over time with periodic network checks, speed tests, and browsable HTML reports.

[View the anonymized sample report](sample-report-2026-10.html)

## What It Measures

- Router and internet latency, packet loss, and reachability
- Wi-Fi signal information when macOS makes it available
- DNS response time using Cloudflare and Google public DNS
- Download and upload speed, tested periodically and when serious degradation is detected
- Public IP changes, recorded locally for diagnostics

The monitor samples about every 30 seconds and runs a speed test about every 30 minutes. These checks add network traffic; speed tests can use a noticeable amount of data.

## Install

Requirements: macOS, a logged-in user session, Python 3 (`python3`), and internet access during setup.

From the project directory, run:

```sh
bash setup_broadband_monitor.sh
```

The installer creates `~/broadband-monitor/`, creates a Python virtual environment, installs `speedtest-cli`, and registers a per-user `launchd` service. The service starts at login and restarts if it exits. Administrator privileges are not required.

## Configure

Before installation, edit the configuration near the beginning of [`setup_broadband_monitor.sh`](setup_broadband_monitor.sh):

| Setting | Purpose | Default |
| --- | --- | --- |
| `ROUTER_IP` | Local address of your router | `192.168.0.1` |
| `WIFI_INTERFACE` | Wi-Fi interface name on this Mac | `en0` |
| `EXPECTED_DOWNLOAD` | Expected plan download speed, Mbps | `100.0` |
| `EXPECTED_UPLOAD` | Expected plan upload speed, Mbps | `100.0` |

Update the router address and plan speeds to make the reports meaningful for your connection.

## Reports And Data

The monitor keeps its output on your Mac under `~/broadband-monitor/`:

| Path | Contents |
| --- | --- |
| `reports/index.html` | Index of available daily reports |
| `reports/YYYY-MM-DD.html` | Daily charts and diagnostic summary |
| `data/measurements.csv` | Raw measurements |
| `data/public_ip_history.csv` | Public IP change history |
| `logs/events.log` | Status changes and monitor events |

Open the report index with:

```sh
open ~/broadband-monitor/reports/index.html
```

Remove the background service without deleting collected measurements:

```sh
~/broadband-monitor/venv/bin/python ~/broadband-monitor/broadband_monitor.py --uninstall
```

## Privacy And Limits

Measurements, logs, and reports are stored locally. The monitor contacts public services for the public IP check, internet connectivity check, DNS checks, and speed tests. The sample report is anonymized: its public IP, exact reporting window, and detailed monitoring-gap timestamps have been removed.

Network measurements can help distinguish local Wi-Fi/router symptoms from broader internet symptoms, but they do not independently prove that an ISP is at fault. Treat reports as diagnostic evidence, not a service guarantee.