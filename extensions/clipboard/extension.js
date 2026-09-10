'use strict';
// The clipboard extension (ADR-0012), daemon half: in every Dev Container
// window, read the user-scope coverage settings, run the clipboard daemon on
// 127.0.0.1:47820 (or confirm another window's daemon owns the port), and
// restart it whenever the settings change. The Cmd+V gesture half lives in
// its own module once issue #63 lands.

const vscode = require('vscode');
const { coverage: makeCoverage } = require('./lib/coverage');
const { createSupervisor } = require('./lib/supervisor');
const { spawnDaemon, probeHealth, PORT } = require('./lib/host');

const SECTION = 'adc.clipboard';
const KEYS = ['images', 'files', 'text'];

// The daemon serves every container on the Mac, so it enforces the value
// from user settings only: a workspace override narrows that window's
// gesture (issue #63) and can never widen what the daemon serves.
function userScopeCoverage() {
  const cfg = vscode.workspace.getConfiguration(SECTION);
  const input = {};
  for (const key of KEYS) {
    const info = cfg.inspect(key);
    input[key] = info && info.globalValue !== undefined ? info.globalValue : info && info.defaultValue;
  }
  return makeCoverage(input);
}

function isDevContainerWindow() {
  return typeof vscode.env.remoteName === 'string' && vscode.env.remoteName.startsWith('dev-container');
}

function activate(context) {
  if (!isDevContainerWindow()) return;

  const output = vscode.window.createOutputChannel('adc clipboard');
  const status = vscode.window.createStatusBarItem('adc.clipboard', vscode.StatusBarAlignment.Right, 50);
  status.name = 'adc clipboard';
  context.subscriptions.push(output, status);

  const log = (line) => output.appendLine(`${new Date().toISOString().slice(11, 19)} ${line}`);

  const render = (state) => {
    status.backgroundColor = undefined;
    status.command = undefined;
    switch (state.kind) {
      case 'serving':
        status.text = '$(clippy) adc';
        status.tooltip = `adc clipboard daemon: serving containers from this window on 127.0.0.1:${PORT}\n`
          + `coverage: images ${state.coverage.images}, files ${state.coverage.files}, text ${state.coverage.text}`;
        break;
      case 'elsewhere':
        status.text = '$(clippy) adc';
        status.tooltip = `adc clipboard daemon: served by another Dev Container window (pid ${state.health.pid}, v${state.health.version})`;
        break;
      case 'foreign':
        status.text = '$(warning) adc clipboard';
        status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
        status.tooltip = `Port 127.0.0.1:${PORT} is owned by a process that is not the adc clipboard daemon. `
          + 'Pasting screenshots into Claude Code in the container will not work until it is freed.';
        break;
      case 'crashed':
        status.text = '$(warning) adc clipboard';
        status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
        status.tooltip = `adc clipboard daemon exited (code ${state.code}); retrying in ${Math.round(state.retryIn / 1000)} s. See the "adc clipboard" output.`;
        break;
      default:
        status.text = '$(clippy) adc';
        status.tooltip = `adc clipboard daemon: ${state.kind}`;
    }
    status.show();
  };

  const supervisor = createSupervisor({
    spawn: (cov) => spawnDaemon(cov, { port: PORT, log }),
    probe: () => probeHealth({ port: PORT }),
    onState: render,
    log,
  });
  context.subscriptions.push({ dispose: () => supervisor.stop() });

  const apply = () => {
    try {
      supervisor.setCoverage(userScopeCoverage());
    } catch (err) {
      log(`invalid coverage settings: ${err.message}`);
      vscode.window.showWarningMessage(`adc clipboard: ${err.message}`);
    }
  };
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration((e) => {
    if (e.affectsConfiguration(SECTION)) apply();
  }));
  apply();
}

function deactivate() {}

module.exports = { activate, deactivate, userScopeCoverage };
