// `client` shim: assertions, test collection, globals and logging.
// `client.test` never throws: a failing body is recorded so the harness can
// report it while the process still exits 0.
export function formatValue(value) {
  if (typeof value === 'string') {
    return value;
  }
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function errorText(error) {
  if (error && error.message) {
    return String(error.message);
  }
  return String(error);
}

export function createClient(state) {
  function log(...args) {
    state.logs.push(args.map(formatValue).join(' '));
  }

  function assert(condition, message) {
    if (!condition) {
      throw new Error(message || 'assertion failed');
    }
  }

  function test(name, fn) {
    const record = { name: String(name), pass: true, message: '' };
    state.tests.push(record);
    let outcome;
    try {
      outcome = fn();
    } catch (error) {
      if (error && error.__rikuestoExit) {
        throw error;
      }
      record.pass = false;
      record.message = errorText(error);
      return false;
    }
    if (outcome && typeof outcome.then === 'function') {
      const settled = outcome.then(
        () => true,
        (error) => {
          if (error && error.__rikuestoExit) {
            throw error;
          }
          record.pass = false;
          record.message = errorText(error);
          return false;
        },
      );
      state.pending.push(settled);
      return settled;
    }
    return true;
  }

  function exit() {
    const stop = new Error('client.exit()');
    stop.__rikuestoExit = true;
    throw stop;
  }

  function setHeader(name, value) {
    const key = String(name);
    for (const pair of state.headerOverrides) {
      if (String(pair[0]).toLowerCase() === key.toLowerCase()) {
        pair[1] = String(value);
        return;
      }
    }
    state.headerOverrides.push([key, String(value)]);
  }

  function getHeader(name) {
    const key = String(name).toLowerCase();
    for (const pair of state.headerOverrides) {
      if (String(pair[0]).toLowerCase() === key) {
        return pair[1];
      }
    }
    return null;
  }

  const globalApi = {
    set(name, value) {
      state.globals[String(name)] = value;
    },
    get(name) {
      const key = String(name);
      return Object.prototype.hasOwnProperty.call(state.globals, key) ? state.globals[key] : null;
    },
    clear(name) {
      delete state.globals[String(name)];
    },
    clearAll() {
      state.globals = {};
    },
    headers: { set: setHeader, get: getHeader },
  };

  return { log, assert, test, exit, global: globalApi };
}
