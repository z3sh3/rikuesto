// `request` shim (pre-request phase).
// `bodySubstituted` is optional in the payload: when the driver already ran the
// substitution pass it can hand the resolved text over, otherwise the raw body
// is the best answer available before substitution happens.
function asPairs(value) {
  if (Array.isArray(value)) {
    return value.filter((pair) => Array.isArray(pair) && pair.length >= 2).map((pair) => [pair[0], pair[1]]);
  }
  if (value && typeof value === 'object') {
    return Object.keys(value).map((key) => [key, value[key]]);
  }
  return [];
}

export function createRequest(payload, state) {
  const data = payload.request || {};
  const environment = payload.environment && typeof payload.environment === 'object' ? payload.environment : {};

  const variables = {
    set(name, value) {
      state.vars[String(name)] = value;
    },
    get(name) {
      const key = String(name);
      return Object.prototype.hasOwnProperty.call(state.vars, key) ? state.vars[key] : null;
    },
  };

  const headers = { all: asPairs(data.headers) };

  const body = {
    getRaw() {
      return data.body == null ? '' : String(data.body);
    },
    tryGetSubstituted() {
      return data.bodySubstituted == null ? body.getRaw() : String(data.bodySubstituted);
    },
  };

  return {
    method: data.method == null ? 'GET' : String(data.method),
    url: data.url == null ? '' : String(data.url),
    variables,
    environment: {
      get(name) {
        const key = String(name);
        return Object.prototype.hasOwnProperty.call(environment, key) ? environment[key] : null;
      },
    },
    headers,
    body,
  };
}
