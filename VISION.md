# Vigil — Product Vision and Operating Model

**Project:** Vigil
**Organisation:** GodspeedHQ
**Repository:** <https://github.com/godspeedhq/vigil>
**Licence:** Apache License 2.0
**Status:** Product vision and architectural direction. The technical rules are in [SPECIFICATION.md](SPECIFICATION.md).

## 1. Vision

Vigil is a lightweight, host-native script supervision and metrics delivery system for Windows, Linux and macOS.

Its purpose is simple:

> Run existing scripts reliably, turn their output into metrics, and deliver those metrics to an organisation's existing observability infrastructure.

Vigil does not interpret business metrics, determine alert thresholds, generate dashboards or attempt to replace monitoring backends. Its responsibilities are execution, supervision, recovery and delivery.

The operating principle is:

> Install once. Drop in scripts. Configure locally or remotely. Vigil handles the rest.

## 2. Core Architecture

Vigil separates three responsibilities.

### Scripts — data collection

Scripts contain the knowledge required to inspect the monitored system. They may collect information about:

- Operating-system health.
- Databases and application services.
- Storage and filesystem capacity.
- Network connectivity.
- Hardware sensors and devices.
- Certificates and security-related conditions.
- Custom business applications.
- Any other system accessible through native scripting or existing operating-system tools.

Scripts produce output according to Vigil's defined metric contract. Vigil does not need to understand what those metrics mean.

### Vigil — reliable execution and delivery

Vigil is responsible for:

- Discovering and validating configuration.
- Scheduling scripts.
- Executing scripts.
- Enforcing runtime and concurrency limits.
- Supervising worker processes.
- Handling execution failures.
- Preserving and reconciling worker state.
- Capturing logs and metrics.
- Spooling telemetry locally.
- Delivering telemetry to configured backends.
- Detecting and applying configuration changes without service restarts.

Vigil is deliberately application-agnostic.

### Observability backend — interpretation

Existing observability systems handle:

- Metric storage and queries.
- Dashboards and visualisation.
- Alerting and thresholds.
- Correlation and analysis.
- Fleet visibility.
- Reporting and operational intelligence.

Examples include Datadog, Splunk, Prometheus-compatible systems and OpenTelemetry-based pipelines. Vigil must not duplicate functionality already provided by these systems.

## 3. Local-First Operation

Local configuration and local scripts are the default operating mode.

An operator installs Vigil as an operating-system service, places scripts in the designated local directory and declares the jobs in one configuration file. Each Vigil instance has exactly one configuration file: jobs are simple entries in it that name a script, a schedule and where the results go.

Vigil discovers the configuration, validates it and schedules the declared jobs. No central server, Git repository or network-accessible configuration source is required.

The basic workflow is:

1. Install Vigil.
2. Add a script.
3. Add the job to the configuration file.
4. Allow Vigil to discover and activate the job.
5. Observe the resulting telemetry in the configured backend.

Adding, removing or modifying job configuration must not require restarting the Vigil service. Existing workers continue according to their established lifecycle and recovery rules. Invalid configuration changes must not replace the last known valid configuration.

## 4. Optional Remote Configuration

Vigil may optionally retrieve its configuration from a remote source. Retrieval mechanisms in the first version:

- A local or network path (a file share or mounted filesystem).
- Git.
- HTTPS.
- SFTP.

Other mechanisms may follow when they can be used securely. Plain FTP and plain HTTP are not supported, because they expose credentials and content in transit.

The local configuration file then says only where the real configuration is, and Vigil fetches it. There is still one configuration per instance, so a setting never has more than one place it can come from. Usage can be fully local, mixed (local configuration with some scripts fetched remotely) or fully remote.

Remote configuration is an optional extension of the local-first model. It must not require a different Vigil edition, separate agent or central Vigil management server.

The configuration source determines the desired jobs, their settings and the scripts they reference. The core supervisor remains unchanged regardless of where configuration originates.

Where configuration comes from is always decided on the host itself. A remotely fetched configuration can never change its own source, so a mistake or compromise in one file cannot redirect a fleet elsewhere.

## 5. Script Sources

Job configurations may reference scripts stored locally or remotely. A script may be retrieved from:

- A local filesystem path.
- A Git repository at a specified tag, commit or branch.
- An HTTPS endpoint.
- An SFTP-accessible location.

Vigil retrieves remote scripts and stores them locally before execution. Workers execute the locally activated script version, not a live remote script.

Script retrieval is independent of the scheduling and supervision mechanisms. Optional retrieval dependencies, such as the Git command-line client, are required only when the corresponding retrieval method is used.

## 6. Configuration-Driven Reconciliation

The configuration is the authoritative declaration of which script version should execute. A script pinned to a tag, commit or digest never changes underneath a host; a script follows a branch or a shared folder only when its source is declared that way.

The reconciliation process is:

1. Vigil checks its configured local or remote configuration sources on a schedule.
2. If the configuration is unchanged and every script it references is present locally and intact, nothing is retrieved.
3. If the configuration changes, Vigil validates the proposed configuration.
4. Vigil identifies newly declared or modified script references.
5. It retrieves the required script versions.
6. It verifies their expected integrity where specified.
7. It stages the complete update locally.
8. It activates the new configuration for future executions.

Script updates are therefore intentional and configuration-driven. A script maintainer may publish multiple script versions without affecting deployed Vigil instances. Only an approved configuration change causes Vigil to adopt a different version.

### Atomic activation

An update must not partially activate a configuration whose required scripts have not been successfully retrieved and validated.

If retrieval or validation fails, Vigil retains the last known good configuration and locally cached scripts, including across a restart.

Running workers must not be interrupted merely because a new script version becomes available.

## 7. Centralised Fleet Operation

Organisations may deploy Vigil across physical servers and virtual machines while managing configuration from a shared location. A typical workflow is:

1. Provision servers with the required business applications.
2. Install Vigil once on each server.
3. Configure each instance to use an approved configuration source.
4. Publish monitoring scripts to approved repositories or file servers.
5. Test and release new script versions.
6. Update the central configuration to reference the approved versions.
7. Vigil instances discover the change and reconcile their local scripts.
8. Subsequent executions use the newly activated versions.

No administrator needs to log into every server to update monitoring scripts. No Vigil service restart is required for ordinary job or script configuration changes.

Each instance operates independently and continues using its last known good local configuration if the remote source becomes unavailable.

### Fleet visibility

Vigil does not require its own fleet management dashboard. Each instance emits telemetry identifying:

- Host identity.
- Active configuration revision — one identifier covering the configuration and the content of every script it activates, so equal revisions mean identical hosts.
- Last successful configuration check.
- Configuration retrieval failures.
- Script retrieval or validation failures.
- Job execution health.
- Telemetry delivery health.

The organisation's existing observability backend can determine which hosts have converged, which remain on older versions and which have stopped reporting.

Deployment is eventually consistent, not necessarily simultaneous across every host.

## 8. Native Operating-System Footprint

Vigil is implemented using native scripting environments.

**Windows**

- Windows PowerShell 5.1 or later.
- NSSM as the initial external Windows service wrapper.
- Existing Windows operating-system facilities for execution and process management.

**Linux**

- Bash-compatible implementation.
- Native operating-system process facilities.
- systemd for service management where supported.

**macOS**

- Bash-compatible implementation.
- Native operating-system process facilities.
- launchd for service management.

Vigil must not require a custom compiled agent, Python, Java, Node.js or a dedicated application runtime for core operation. Optional retrieval or transport mechanisms may introduce optional dependencies.

The exact supported shell versions and platform-specific requirements remain governed by the technical specification.

## 9. Hot Configuration Changes

Vigil is installed as a persistent service. Routine operational changes must not require restarting that service. These include:

- Adding a job.
- Removing a job.
- Enabling or disabling a job.
- Changing a schedule.
- Updating job arguments.
- Updating script versions.
- Changing supported telemetry settings.
- Updating configuration sources.

Changes must be validated before activation.

Removing or modifying a job must not automatically terminate an already-running worker. Workers follow the lifecycle and cancellation policies defined by the technical specification.

The supervisor and configuration reconciliation mechanisms must remain operational while changes are applied.

## 10. Reliability

Vigil's primary value is not merely running scripts. Its value is running them reliably. The system must provide:

- Bounded concurrency.
- Runtime deadlines.
- Worker failure detection.
- Conservative orphan recovery.
- Safe process ownership handling.
- Persistent execution state.
- Atomic state publication.
- Local telemetry spooling.
- Bounded retries and retention.
- Explicit delivery failure reporting.
- Recovery after supervisor restarts.
- Last-known-good configuration fallback.

Telemetry delivery must not indefinitely block script execution.

Vigil must not claim unconditional exactly-once delivery or exactly-once execution of external side effects. Its guarantees must be documented and validated against supported operating systems.

## 11. Security and Existing Organisational Controls

Vigil is not a replacement for an organisation's existing deployment governance. Organisations already manage:

- Source repository permissions.
- Code review and approval.
- Script release processes.
- Service identities.
- Secrets and credentials.
- Network access.
- Production change controls.

Vigil should integrate with these controls rather than reproduce them.

Remote configuration is a source of executable deployment instructions and must therefore be trusted. Retrieved scripts should be pinned to immutable versions or verified against approved content digests where practical. Vigil uses only transports that protect content in transit and verify the server's identity.

Vigil must execute jobs with explicitly configured operating-system permissions.

The system must not invent its own secrets-management platform or remote administration service.

## 12. Scope Boundaries

Vigil is primarily designed for physical servers and virtual machines. It may run directly on the operating systems of servers that also host Kubernetes.

It is not intended to become:

- A Kubernetes operator.
- A container orchestration system.
- A distributed workflow engine.
- A configuration-management replacement.
- A central monitoring platform.
- An alerting engine.
- A dashboard system.
- An application-specific monitoring framework.

Vigil supervises host-level scripts and delivers their outputs. Kubernetes, application platforms and observability backends retain their own responsibilities.

## 13. Extensibility

Vigil's core should eventually become stable and change relatively infrequently. New monitoring capabilities should ordinarily be introduced through scripts, not modifications to the supervisor.

A contributor should be able to add a useful monitoring script without understanding Vigil's internal scheduling, recovery or telemetry implementation: a script, its job configuration file, and nothing else.

The complexity of contributing a script must not increase simply because Vigil's internal implementation becomes more sophisticated.

The long-term architectural model is analogous to railway infrastructure:

- **Tracks:** Vigil's stable execution and supervision framework.
- **Trains:** independently developed and versioned scripts.
- **Timetable:** local or remote configuration.
- **Signalling:** scheduling, runtime limits and recovery rules.
- **Control visibility:** the organisation's existing observability backend.

The infrastructure remains dependable while scripts evolve independently.

## 14. Commercial Model

Vigil's core functionality remains open source under Apache License 2.0. Local operation, remote configuration, script retrieval, supervision and telemetry delivery should not be artificially divided into free and paid editions.

Organisations may pay for:

- Professional support.
- Deployment assistance.
- Integration services.
- Operational troubleshooting.
- Compatibility testing.
- Custom development.
- Agreed support commitments.

Revenue is based on services and support, not withholding essential product functionality.

## 15. Product Positioning

Vigil is not the first system to execute scripts and export metrics. Existing monitoring products, including Telegraf, Checkmk, Zabbix and Nagios, demonstrate established demand for script-based monitoring.

Vigil's intended differentiation is the combination of:

- Native-script implementation.
- Minimal installation dependencies.
- Local-first operation.
- Optional remote configuration and script distribution.
- Hot configuration reconciliation.
- Independent worker supervision and recovery.
- Backend-independent metrics delivery.
- No mandatory central management server.
- No application-specific compiled monitoring agent.

These are design objectives; production reliability and comparative advantages must be demonstrated through implementation and testing.

## 16. Product Message

**Vigil — Your scripts. Your metrics. Reliable delivery.**

Vigil is a lightweight, host-native script supervisor for Windows, Linux and macOS.

Write a PowerShell or Bash script that produces metrics. Vigil schedules it, supervises its execution, handles failures and delivers the results to your existing observability platform.

Start with local files. Optionally manage configuration and script versions remotely across an entire server fleet.

Add, remove or update jobs without restarting the service.

No custom compiled monitoring agent. No mandatory central control plane. No application-specific monitoring binaries.

Vigil doesn't interpret your metrics. Your observability backend handles dashboards, alerts and analysis.

Install once. Drop in scripts. Vigil does the rest.

## 17. Final Architectural Principle

Vigil must remain simple to operate even when its internal reliability mechanisms are sophisticated.

- Configuration determines what runs.
- Scripts determine what information is collected.
- Vigil determines when and how reliably scripts execute and how their outputs are delivered.
- The observability backend determines what those outputs mean.

The core remains stable. The scripts evolve. The operator stays in control.
