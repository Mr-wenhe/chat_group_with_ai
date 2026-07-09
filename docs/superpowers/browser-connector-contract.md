# Browser Connector Contract

The local agent bridge accepts browser context updates through:

`POST http://127.0.0.1:54263/browser/update`

Payload:

```json
{
  "url": "https://example.com/page",
  "title": "Example Page",
  "selectedText": "optional user selection",
  "pageText": "visible readable text from the active tab",
  "capturedAt": "2026-07-09T12:00:00.000Z"
}
```

The Flutter app reads the latest explicit update through:

`POST http://127.0.0.1:54263/browser/current-tab`

If no context has been posted yet, the bridge returns:

```json
{
  "error": "browser_context_missing"
}
```
