// `response` shim (response-handler phase).
// `body` is auto-parsed only when the reported content type is JSON; a parse
// failure falls back to the raw text instead of throwing.
function asPairs(value) {
  if (Array.isArray(value)) {
    return value.filter((pair) => Array.isArray(pair) && pair.length >= 2).map((pair) => [pair[0], pair[1]]);
  }
  if (value && typeof value === 'object') {
    return Object.keys(value).map((key) => [key, value[key]]);
  }
  return [];
}

function decodeBody(data) {
  if (typeof data.bodyBase64 === 'string' && data.bodyBase64 !== '') {
    return Buffer.from(data.bodyBase64, 'base64').toString('utf8');
  }
  return data.body == null ? '' : String(data.body);
}

function isJsonMimeType(mimeType) {
  const mime = String(mimeType || '').toLowerCase();
  return mime === 'application/json' || mime === 'text/json' || mime.endsWith('+json');
}

function parseCookies(setCookieValues) {
  const cookies = {};
  for (const value of setCookieValues) {
    const first = String(value).split(';')[0];
    const index = first.indexOf('=');
    if (index <= 0) {
      continue;
    }
    cookies[first.slice(0, index).trim()] = first.slice(index + 1).trim();
  }
  return cookies;
}

export function createResponse(payload) {
  const data = payload.response || {};
  const pairs = asPairs(data.headers);
  const headerMap = Object.create(null);
  for (const pair of pairs) {
    const key = String(pair[0]).toLowerCase();
    if (!headerMap[key]) {
      headerMap[key] = [];
    }
    headerMap[key].push(String(pair[1]));
  }

  const declared = data.contentType && typeof data.contentType === 'object' ? data.contentType : {};
  const headerType = (headerMap['content-type'] && headerMap['content-type'][0]) || '';
  const [headerMime, headerCharset] = headerType.split(';').map((part) => part.trim());
  const contentType = {
    mimeType: declared.mimeType ? String(declared.mimeType) : headerMime || '',
    charset: declared.charset ? String(declared.charset) : (headerCharset || '').replace(/^charset=/i, ''),
  };

  const raw = decodeBody(data);
  let body = raw;
  if (isJsonMimeType(contentType.mimeType)) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = raw;
    }
  }

  return {
    status: data.status,
    body,
    contentType,
    headers: {
      valueOf(name) {
        const values = headerMap[String(name).toLowerCase()];
        return values && values.length > 0 ? values[0] : null;
      },
      valuesOf(name) {
        const values = headerMap[String(name).toLowerCase()];
        return values ? values.slice() : [];
      },
      all: pairs,
    },
    cookiesByName: parseCookies(headerMap['set-cookie'] || []),
  };
}
