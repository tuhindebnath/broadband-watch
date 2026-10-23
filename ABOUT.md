# About Broadband Watch

Broadband Watch is a lightweight, privacy-first network monitor for macOS. It is designed for people who want to understand whether their home internet problems are caused by Wi‑Fi conditions, router instability, DNS latency, or an upstream ISP issue.

Instead of relying on a single measurement, the tool continuously samples key network signals and saves them locally. Over time it builds a historical record of latency, packet loss, signal quality, DNS response time, and throughput. Those measurements are summarized into daily HTML reports that can be opened directly from your Mac.

## Why it exists

Most internet complaints are vague: "it feels slow," "the connection drops," or "the Wi‑Fi is unreliable." A one-off speed test rarely explains the pattern. Broadband Watch gives you evidence over time so you can tell whether the problem is persistent or only appears during certain conditions.

It is especially useful for:

- Troubleshooting slow home internet
- Comparing ISP performance across time or providers
- Checking whether Wi‑Fi signal quality is degrading
- Diagnosing router or DNS issues before escalating a support ticket
- Keeping all measurements private on your own machine

## How it works

The monitor runs as a per-user background service on macOS. It periodically checks:

- Router reachability
- Internet connectivity
- Wi‑Fi signal strength and channel information when available
- DNS response time against public resolvers
- Download and upload speed using periodic speed tests
- Public IP changes for diagnostics

All data is stored under `~/broadband-monitor/` and can be inspected locally as CSV files or rendered HTML reports. The project intentionally avoids sending your network details to a hosted service.

## Project goals

- Local-first monitoring with no external reporting platform required
- Simple setup for everyday users on macOS
- Clear visual summaries for troubleshooting and evidence gathering
- Minimal dependence on administrator privileges or special infrastructure
- Useful data without sacrificing privacy

## Acknowledgements

This project was developed with the support of multiple AI coding tools, which helped with brainstorming, implementation, debugging, and documentation cleanup. It is a small, appreciative nod to the growing ecosystem of AI-assisted software development: practical, iterative, and often surprisingly collaborative.

## Limitations

Broadband Watch is a practical diagnostic tool, not a guarantee of ISP fault or a replacement for a full network monitoring stack. It can show patterns and help distinguish local problems from upstream ones, but it does not independently prove that a provider is at fault in every case.

Treat the reports as evidence to guide troubleshooting, not as a contractual or legal measurement standard.
