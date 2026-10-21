// a test describes a fake system: none of this is on the map
app.get('/api/only-in-tests', x);
const k = process.env.TEST_ONLY_KEY;
fetch('/api/nowhere');
