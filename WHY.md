# Why Vigil?

- [It started with a problem I needed to solve](#it-started-with-a-problem-i-needed-to-solve)
- [From a Windows problem to a cross-platform tool](#from-a-windows-problem-to-a-cross-platform-tool)
- [Vigil isn't here to replace your existing tools](#vigil-isnt-here-to-replace-your-existing-tools)
- [It doesn't have to be zero-sum](#it-doesnt-have-to-be-zero-sum)
- [Why not just use cron, Telegraf or OpenTelemetry?](#why-not-just-use-cron-telegraf-or-opentelemetry)
- [More open source, more choice](#more-open-source-more-choice)
- [An invitation, not a prescription](#an-invitation-not-a-prescription)

## It started with a problem I needed to solve

Vigil began with a practical problem.

I needed a reliable way to run and monitor operational scripts on Windows servers hosting a database. PowerShell was already there, and the environment already supported running operational scripts as Windows services.

Introducing another monitoring agent would have meant more approvals and more operational considerations. Rather than add another dependency, I built on the tools already available.

That approach worked, and it got me thinking: surely other people run into similar constraints?

That's where the idea for Vigil began.

## From a Windows problem to a cross-platform tool

The original problem happened to involve Windows, but the requirements behind it weren't specific to Windows, or to databases.

Linux has cron and systemd timers. macOS has launchd. Windows has Task Scheduler and Windows services. These are established tools that work well for many purposes.

What I wanted was a consistent way to schedule, run, supervise and observe operational scripts and programs across Windows, Linux and macOS. That meant predictable behaviour for scheduling, overlapping runs, timeouts, failures, recovery and telemetry, whatever the operating system.

Vigil is itself written in the scripting languages administrators already know: Windows PowerShell 5.1, which every supported Windows has, and bash on Linux and macOS (bash 3.2, which macOS still ships, or later). There's no runtime to install and nothing to compile. The one program it ships is NSSM, the long-standing tool for running a script as a Windows service.

It isn't an attempt to reinvent the operating system's scheduler. It's an attempt to give one consistent operational model across platforms.

## Vigil isn't here to replace your existing tools

There are already excellent tools for scheduling, monitoring and observability. Cron, systemd timers, launchd, Telegraf, the OpenTelemetry Collector and many others have earned their place in production.

If your existing tools meet your requirements, keep using them.

Seriously.

Vigil isn't an argument that those tools fall short, nor an attempt to convince you to replace something that already works. Different environments have different constraints, and different teams have different preferences:

- Some organisations are perfectly comfortable deploying dedicated monitoring agents. Others work where introducing more software is hard, but operational scripts are already part of the established workflow.
- Some teams have standardised on a particular scheduler or monitoring stack. Others manage a mix of Windows, Linux and macOS systems, and would like one consistent way to manage operational jobs.

Vigil is simply another option.

## It doesn't have to be zero-sum

Using Vigil doesn't mean abandoning your existing infrastructure.

You can use Vigil to schedule, run and supervise operational jobs, and send its telemetry through an existing OpenTelemetry Collector, which goes on processing and routing it to your observability platforms as before.

Or Vigil can send telemetry directly: to Datadog and Splunk, to anything that takes OpenTelemetry (OTLP), Prometheus and Grafana's stack among them, or to a Prometheus text file for node_exporter's or windows_exporter's textfile collector.

Your dashboards, alerting rules, telemetry pipelines and other investments don't have to go anywhere. Vigil can complement the tools you already use.

And if you only need Vigil on a handful of machines, and something else everywhere else, that's perfectly fine too. There's no need to standardise your whole infrastructure around it.

## Why not just use cron, Telegraf or OpenTelemetry?

You absolutely can.

- If all you need is a command that runs periodically, cron or a systemd timer may be all you need.
- If Telegraf already collects the metrics you care about, there's no reason to replace it.
- If the OpenTelemetry Collector already handles your telemetry pipeline, keep it.

Vigil focuses on the lifecycle of operational scripts and programs: scheduling, overlapping runs, timeouts, persistent run state, recovery from failures, configuration and scripts fetched from a central source, secrets from external stores, and telemetry.

None of these ideas is unique to Vigil. Other tools implement some or many of them, often in different ways. Vigil brings them together in one cross-platform supervisor, written in PowerShell and bash.

Whether that combination is useful depends entirely on your requirements. You don't need to justify using something else.

## More open source, more choice

I believe having more open-source options is a good thing.

Open source shouldn't be a competition where one project has to defeat another to justify its existence. Projects come from different experiences, constraints and design decisions. Sometimes their capabilities overlap; sometimes they complement one another. That's healthy.

Vigil is released under the [Apache License 2.0](LICENSE). You're welcome to use it, read its code, change it, contribute to it or build on it, under the terms of that licence.

And if another tool works better for you, use that instead.

The goal isn't to make Vigil the answer to every operational problem. It's to make it a dependable answer to the problems it was designed to solve.

## An invitation, not a prescription

I built Vigil because I needed something that worked within the constraints of my environment. As the idea grew, I realised the same approach might be useful to others managing operational scripts and programs across different operating systems. So I decided to make it available.

I'm not asking anyone to replace tools they're happy with, and I'm not claiming Vigil is the only way to solve these problems.

If it solves a problem you have, you're welcome to use it. If your existing setup works perfectly well, keep it.

Vigil doesn't need to replace what already works. It just needs to be useful where it's needed.
