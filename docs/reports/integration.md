# Integration run: test.http

- nvim 0.12, curl curl 8.23.0 (x86_64-w64-mingw32) libcurl/8.23.0 Schannel zlib/1.3.2 brotli/1.2.1 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.5 libssh2/1.11.1 WinLDAP
- 18 requests, 0 failure(s), 19380ms total

| # | method | url | status | time (ms) | size (B) | verdict |
|---|---|---|---|---|---|---|
| 1 | GET | `https://jsonplaceholder.typicode.com/posts` | 200 | 1036 | 27520 | PASS |
| 2 | GET | `https://jsonplaceholder.typicode.com/posts?userId=1&_limit=5&_sort=id&_order=desc` | 200 | 712 | 1308 | PASS |
| 3 | GET | `https://jsonplaceholder.typicode.com/posts/1` | 200 | 758 | 292 | PASS |
| 4 | GET | `https://jsonplaceholder.typicode.com/posts/1/comments` | 200 | 758 | 1510 | PASS |
| 5 | GET | `https://jsonplaceholder.typicode.com/albums/1/photos` | 200 | 1056 | 10216 | PASS |
| 6 | GET | `https://jsonplaceholder.typicode.com/todos?userId=1&_limit=10` | 200 | 1071 | 1121 | PASS |
| 7 | POST | `https://jsonplaceholder.typicode.com/posts` | 201 | 910 | 117 | PASS |
| 8 | POST | `https://jsonplaceholder.typicode.com/users` | 201 | 1188 | 503 | PASS |
| 9 | PUT | `https://jsonplaceholder.typicode.com/posts/1` | 200 | 982 | 137 | PASS |
| 10 | PUT | `https://jsonplaceholder.typicode.com/todos/1` | 200 | 1038 | 82 | PASS |
| 11 | PATCH | `https://jsonplaceholder.typicode.com/posts/1` | 200 | 953 | 236 | PASS |
| 12 | PATCH | `https://jsonplaceholder.typicode.com/comments/1` | 200 | 1295 | 261 | PASS |
| 13 | DELETE | `https://jsonplaceholder.typicode.com/posts/1` | 200 | 964 | 2 | PASS |
| 14 | DELETE | `https://jsonplaceholder.typicode.com/albums/1` | 200 | 762 | 2 | PASS |
| 15 | HEAD | `https://jsonplaceholder.typicode.com/posts/1` | 200 | 1657 | 0 | PASS |
| 16 | OPTIONS | `https://jsonplaceholder.typicode.com/posts` | 204 | 1060 | 0 | PASS |
| 17 | GET | `https://jsonplaceholder.typicode.com/posts/999` | 404 | 900 | 2 | PASS |
| 18 | POST | `https://jsonplaceholder.typicode.com/invalid-resource` | 404 | 1423 | 2 | PASS |
