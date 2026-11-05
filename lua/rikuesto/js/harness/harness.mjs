// rikuesto JS harness: reads one JSON payload from stdin, runs the user script
// with the sandbox shims in scope, and always writes exactly one JSON object to
// stdout. Nothing the script prints may reach stdout, and the process must never
// die with a non-zero code (DESIGN §8.3/§8.4).
import { readFileSync } from 'node:fs';

import crypto from './shims/crypto.mjs';
import { createClient, formatValue } from './shims/client.mjs';
import { createRequest } from './shims/request.mjs';
import { createResponse } from './shims/response.mjs';

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

let emitted = false;
let activeState = null;

function emit(result) {
  if (emitted) {
    return;
  }
  emitted = true;
  process.stdout.write(JSON.stringify(result));
}

function emptyResult() {
  return { vars: {}, globals: {}, headerOverrides: [], bodyOverride: null, logs: [], tests: [], errors: [] };
}

function errorRecord(error) {
  return {
    message: error && error.message ? String(error.message) : String(error),
    stack: error && error.stack ? String(error.stack) : '',
  };
}

function captureConsole(logs) {
  const write = (...args) => logs.push(args.map(formatValue).join(' '));
  return { log: write, info: write, warn: write, error: write, debug: write };
}

function createState(payload) {
  const vars = payload.vars && typeof payload.vars === 'object' ? payload.vars : {};
  const globals = payload.globals && typeof payload.globals === 'object' ? payload.globals : {};
  return {
    vars: Object.assign({}, vars),
    globals: Object.assign({}, globals),
    headerOverrides: [],
    bodyOverride: null,
    logs: [],
    tests: [],
    errors: [],
    pending: [],
  };
}

function buildScope(payload, state) {
  const scope = {
    client: createClient(state),
    crypto,
    console: captureConsole(state.logs),
  };
  if (payload.phase === 'pre') {
    scope.request = createRequest(payload, state);
  } else {
    scope.response = createResponse(payload);
  }
  return scope;
}

async function runScript(scope, script) {
  const names = Object.keys(scope);
  const compiled = new AsyncFunction(...names, String(script == null ? '' : script));
  return compiled(...names.map((name) => scope[name]));
}

async function main() {
  const payload = JSON.parse(readFileSync(0, 'utf8'));
  const state = createState(payload);
  activeState = state;
  try {
    await runScript(buildScope(payload, state), payload.script);
  } catch (error) {
    if (!(error && error.__rikuestoExit)) {
      state.errors.push(errorRecord(error));
    }
  }
  await Promise.allSettled(state.pending);
  return state;
}

// A floating promise or a stray timer callback must not turn the exit code
// non-zero after the envelope has been written.
process.on('uncaughtException', (error) => {
  if (!emitted) {
    const result = emptyResult();
    result.errors.push(errorRecord(error));
    emit(result);
  }
});
process.on('unhandledRejection', (error) => {
  if (!emitted && activeState) {
    activeState.errors.push(errorRecord(error));
  }
});

try {
  const state = await main();
  const result = emptyResult();
  result.vars = state.vars;
  result.globals = state.globals;
  result.headerOverrides = state.headerOverrides;
  result.bodyOverride = state.bodyOverride;
  result.logs = state.logs;
  result.tests = state.tests;
  result.errors = state.errors;
  emit(result);
} catch (error) {
  const result = emptyResult();
  result.errors.push(errorRecord(error));
  emit(result);
}

process.exitCode = 0;
