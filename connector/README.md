# PaaayIT Card Reader Connector

A lightweight local Windows service that bridges the PaaayIT Flutter POS app
to payment-reader bridge executables for local card-present flows.

```text
Flutter Windows app  →  http://127.0.0.1:17777  →  Connector  →  ePN BBPOS SDK (EpnSdkBridge.exe)  →  Card reader
```

---

## Quick start (stub / testing mode)

```powershell
cd connector
Copy-Item .env.example .env   # then edit CONNECTOR_TOKEN
npm install
node server.js
```

The connector will start on **127.0.0.1:17777** and simulate card transactions
without any hardware.

---

## API

All endpoints except `/health`, `/ready`, and `/health/readiness` require the `X-Connector-Token` header.

| Method | Path                     | Description                                 |
| ------ | ------------------------ | ------------------------------------------- |
| GET    | `/health`                | Liveness check - no auth required           |
| GET    | `/ready`                 | Readiness gate (returns 503 when not ready) |
| GET    | `/health/readiness`      | Detailed readiness diagnostics              |
| GET    | `/reader/status`         | Reader connection state                     |
| GET    | `/reader/support-packet` | Vendor-ready reader/SDK/chirp diagnostics   |
| POST   | `/emv/sale`              | Start card-present transaction (blocking)   |
| POST   | `/emv/cancel`            | Cancel any in-progress sale                 |

### POST `/emv/sale` — request body

```json
{
  "amount": 12.50,
  "invoiceNumber": "INV-001",
  "referenceNumber": "REF-001",
  "clerkId": "01"
}
```

### POST `/emv/sale` — success response

```json
{
  "success": true,
  "transactionId": "12345678",
  "authCode": "ABC123",
  "accountNumber": "XXXX1234",
  "accountType": "Visa",
  "amount": 12.50,
  "status": "approved",
  "message": "Approved"
}
```

---

## Flutter configuration

Build the Windows app with the matching token:

```powershell
flutter run -d windows `
  --dart-define=CHIP_CONNECTOR_TOKEN=your-secret-token `
  ... (other dart-defines)
```

---

## Auto-start at login (Task Scheduler)

Run the installer script once as Administrator:

```powershell
.\install-service.ps1
```

This registers a Task Scheduler task that starts the connector automatically
when the POS operator logs in.

---

## Real hardware integration (ePN BBPOS)

To use a real BBPOS reader with eProcessing Network:

1. Set `DRIVER_MODE=bbpos-sdk` in `.env`.
2. Set `BRIDGE_MODE=bbpos-sdk` in `.env`.
3. Build/publish the bridge from `connector/EpnSdkBridge/build-bridge.ps1`.
4. Ensure `EpnSdkBridge.exe` exists in this folder.
5. Set `EPN_SDK_READY=true` and fill in ePN credentials in `.env`.
6. Restart the connector.

See `card-reader-driver.js` → `BbposSdkDriver` for the bridge protocol.

### Startup gate (production safety)

On startup, the connector now validates:

1. `DRIVER_MODE` is valid.
2. `CONNECTOR_TOKEN` is non-default (unless explicitly overridden for dev).
3. Bridge executable exists for non-stub modes.
4. Required BBPOS runtime DLLs are present.
5. The configured localhost port is available.

If any required check fails, startup exits with code `1` by default.

Use these environment flags only when intentionally running in a temporary degraded local dev mode:

- `CONNECTOR_STRICT_STARTUP=false` (do not fail startup on gate errors)
- `ALLOW_INSECURE_DEV_TOKEN=true` (allow default/placeholder token)
- `BRIDGE_EXECUTABLE_PATH=relative-or-absolute-path-to-exe` (override bridge location)

### Supported readers

- AWC Walker C3X (USB HID, VID 0x15A2)
- BBPOS Chipper series

### Important constraints

- Chip (EMV) and magnetic swipe are supported.
- **Contactless / NFC / tap-to-pay** support depends on reader hardware.
- The connector must run locally on the same Windows machine as the card reader.
- Do not expose port 17777 on the network — it is restricted to 127.0.0.1.
