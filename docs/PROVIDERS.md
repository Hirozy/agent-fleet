# Coding-agent status setup

Fleet displays the status that herdr-core receives from the running program.
For the versions below, start the interactive CLI directly; an additional Fleet
hook or status adapter is not required. Authenticate and complete the provider's
first-run setup yourself before relying on unattended template launches.

## Verified versions and evidence

Checked on macOS with hc **0.1.17**, on **2026-11-04**. These are the versions
examined, not a declaration of minimum versions for every provider.

| Provider | Installed version | Status implementation | Validation performed |
| --- | --- | --- | --- |
| Claude Code | 2.1.311 | Native OSC 7501; upstream introduced it in 2.1.295 | Version command and upstream changelog checked. Isolated startup reached the first-run theme picker with `reported=false`, `status=null`; no authenticated turn tested. |
| Codex CLI | 0.166.0 | Native OSC 7501 in the interactive TUI | Version command, installed binary and matching release source checked. No interactive/model session launched. |
| Pi | 1.5.0 | Native OSC 7501 with terminal capability negotiation | Installed source checked. Isolated interactive startup reported `app=pi`, `state=idle` through Core with no forced override. |

The Core capability query was also checked independently. Tests used temporary
Core sessions and, for Pi and Claude, temporary provider configuration. No user
credentials, settings, or existing sessions were changed; no model prompt was
submitted. These checks do not establish full permission, error, cancellation,
or completion behavior for a real model turn.

## Start from Emacs

```elisp
(agent-fleet-start '("claude") :cwd "/path/to/repo" :display t)
(agent-fleet-start '("codex") :cwd "/path/to/repo" :display t)
(agent-fleet-start '("pi") :cwd "/path/to/repo" :display t)
```

Alternatively use `C-c a n`. These commands must be available on the machine
where Core starts the process. Fleet offers command names, not provider
installation, authentication, or automatic hook configuration.

Use the interactive CLI, with stdout attached to the Core PTY. Print/JSON/RPC
modes and wrappers that redirect stdout are different interfaces and are not
covered by this setup. A remote launch needs the provider and any template on
the remote machine; a local installation does not configure its remote copy.

## Claude Code

No Fleet-specific settings entry is needed for native support. Anthropic's
[changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21295)
announces OSC 7501 support in 2.1.295.

The tested fresh configuration stopped at theme selection before reporting any
status. Attach with `RET`, finish setup and authentication, and inspect the
resulting status before using template-driven startup. Do not classify the
onboarding screen as `idle` or assume every user-facing dialog reports `blocked`.
The ordinary authenticated workflow was not exercised in this validation.

## Codex CLI

The [0.166.0 implementation](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/terminal_program_status.rs)
enables OSC 7501 when stdout is a terminal, except for a detected VTE backend
older than 0.54. It defines `idle`, `working`, `blocked`, `done`, and `error`,
with permission/question/auth reasons for blocked states. It also clears
status when relinquishing the terminal.

Use `codex` in the Core PTY without a status hook. If status is absent, inspect
stdout redirection and inherited terminal detection variables, including an
obsolete `VTE_VERSION`; do not add an undocumented `tui.terminal_status` setting.
Source support is verified here; live behavior for this installed Codex session
has not been tested.

## Pi

Pi 1.5.0 negotiates OSC 7501 with its terminal. Core answered the query in the
isolated test, and Pi then reported `idle` without an extension or override.

The installed terminal implementation accepts `PI_PROGRAM_STATUS=0` to disable
reporting and `PI_PROGRAM_STATUS=1` to force it; other values use negotiation.
Normally leave it unset. For a diagnosed negotiation problem only, scope an
override to one launch:

```elisp
(agent-fleet-start '("env" "PI_PROGRAM_STATUS=1" "pi")
                   :cwd "/path/to/repo" :display t)
```

This forces reporting; it does not establish readiness or fix authentication.
Do not change Emacs's global environment to configure a single agent.

The [terminal implementation](https://github.com/earendil-works/pi/blob/main/packages/tui/src/terminal.ts)
handles negotiation and encoding. The
[interactive reporter](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/interactive/program-status-reporter.ts)
maps agent runs, compaction, dialogs, and settled results to status. Pi 1.5.0's
installed versions of these modules were inspected; only startup `idle` was
tested in a real Core terminal, not a model-driven state cycle.

## Templates and readiness

A template selects a command and opening instructions; it does not enable a
provider's status protocol. Core's default template readiness waits for a status
report. Inspect `first_message` in the launch result/Details: an unsent first
message leaves the already-started program running. Attach, resolve the startup
screen, and submit a reviewed prompt explicitly. Fleet never retries it silently.

Core also offers `ready: quiet`. That is an explicit output-settling heuristic,
not an OSC status integration or proof of readiness. Fleet does not add it to
templates automatically. See the
[Core template contract](https://github.com/herdrdev/herdr-core/blob/master/docs/templates.md#readiness-and-input).

## Check a specific agent

1. Open Dashboard Details (`i`) and check runtime state separately from work
   status. `live` plus `done` is normal; it does not make the agent disposable.
2. For the exact Core report, evaluate this against the active Fleet connection,
   replacing the address with the one shown in the Dashboard:

   ```elisp
   (herdr-core-request "terminal.get" '(:terminal "t7"))
   ```

   `reported` records whether status has been reported; `status` is the current
   root record and can be absent. Read `status.state`, `status.app`, and any
   `status.kind` as the provider reported them. Use `machine/t7` for remote agents.
3. If no status appears, attach and inspect setup/authentication or command
   failure. Check the actual provider version and launch command on that machine.
   An installed executable or a configured template alone does not prove status
   support. Inspect wrapper redirections and provider-specific disabling flags.
4. To check a full turn, explicitly submit a small prompt and observe the pushed
   states. Model requests use the provider's normal account/billing. A turn's
   `done` report is not proof that every background job or subagent has finished;
   do not use it as permission to kill programs or delete code.

Programs without reports remain usable through Fleet. They display `unreported`;
Fleet does not substitute screen scraping, periodic polling, or process liveness
for provider-reported work status.
