Add three features to the inventory API (server.js), each with tests in test/:

1. Validation: POST /items requires `name` (a non-empty string) and `qty` (an integer >= 0); otherwise 400 with `{ "error": "<what is wrong>" }`. A body that is not JSON is 400 too.
2. Filtering: GET /items?name=<text> returns only items whose name contains <text>, case-insensitive; GET /items?minQty=<n> only those with qty >= n; both together combine.
3. Delete: DELETE /items/<id> removes the item and returns 204; an unknown id is 404 `{ "error": "not found" }`.

Keep the existing behaviour and tests passing. The tests run with `node --test`.
