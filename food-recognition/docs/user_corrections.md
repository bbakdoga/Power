# Opt-in user corrections

The app may let users send a corrected scan to improve recognition. This is
**off by default** and nothing is uploaded without an explicit opt-in for
that scan.

## Consent

- The opt-in screen shows the consent text and its version (for example
  `food-corrections-v1`). The version and the time the user agreed are sent
  with every bundle.
- Users can withdraw consent in Settings. The app then stops sending, and a
  withdrawal request removes their earlier scans (matched by `scan_id`, which
  the app keeps locally).
- Accepted consent versions are passed to `food-rec ingest-corrections
  --consent-version food-corrections-v1`; others are discarded.

## Bundle format (schema_version 1)

One `<scan_id>.json` plus `<scan_id>.jpg` per scan. The app re-encodes the
JPEG without EXIF (no GPS, no device or time tags) before upload.

```json
{
  "schema_version": "1",
  "scan_id": "6b0f3c7e-2a43-4f43-9d0b-1c1d6a1c9e21",
  "image_sha256": "<sha256 of the uploaded jpg>",
  "image_width": 3024,
  "image_height": 4032,
  "captured_at": "2026-11-20T19:02:00Z",
  "submitted_at": "2026-11-20T19:03:10Z",
  "app_version": "1.4.0",
  "model_version": "0.1.0",
  "consent": {
    "granted": true,
    "version": "food-corrections-v1",
    "granted_at": "2026-11-20T19:03:05Z",
    "scope": "model-training"
  },
  "regions": [
    {
      "bbox": [410, 1220, 900, 760],
      "predicted": [{"label": "white_rice", "confidence": 0.61}, {"label": "fried_rice", "confidence": 0.22}],
      "confirmed_label": "fried_rice",
      "user_drew_box": false,
      "uncertain": false
    }
  ]
}
```

Bundles must not contain an account id, name, email, location, device id or
advertising id; `ingest-corrections` rejects any bundle that does. Nutrition
values are never part of a bundle.

## Review before training

```
app upload ──► ingest-corrections ──► corrections_pending.jsonl (unreviewed)
                                              │  person reviews in Label Studio
                                              ▼
                       decisions.jsonl {scan_id, decision, reviewer, reviewed_at}
                                              │
                                              ▼
                       promote-corrections ──► images.jsonl + instances.json
```

- `validate` fails on any `user_correction` image that is not `approved`, so
  unreviewed labels cannot reach training even if someone edits files by hand.
- Promoted corrections enter the next frozen dataset version, never an
  existing one.
