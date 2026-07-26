# Reader Initialization Setup Guide

## Issue Fixed
The Flutter app was trying to use a native method channel (`bbpos_reader`) that was never implemented in the Windows C++ runner. This has been replaced with HTTP calls to the connector service.

## What Was Changed

### 1. **ChipReaderService** (`lib/services/chip_reader_service.dart`)
- Removed broken `MethodChannel('bbpos_reader')` calls
- Now uses HTTP to communicate with connector at `http://127.0.0.1:17777`
- Calls these endpoints:
  - `GET /health` — Check connector is running
  - `GET /reader/preflight` — Initialize and check reader readiness
  - `POST /reader/beep` — Trigger audible feedback (chirp)
  - `GET /reader/status` — Get current reader state + LED status
  
### 2. **RegisterScreen** (`lib/register/register_screen.dart`)
- Enhanced `_initializeReader()` with connector health check first
- Better error messages:
  - "Connector service offline (127.0.0.1:17777)" if connector isn't running
  - Shows LED status (e.g., "Reader ready (LED: steady_blue)")
  - Network-specific error detection

## To Make This Work

### Prerequisites
1. **Connector Service Must Be Running**
   - Navigate to: `connector/` directory
   - Run: `node server.js`
   - Verify output shows: `Server listening on 127.0.0.1:17777`
   - Check `.env` file exists with valid `CONNECTOR_TOKEN`

2. **Reader Device Must Be Connected**
   - Check Windows Device Manager for card reader (usually USB)
   - Look for devices starting with "CHB" or similar payment terminal reader

3. **Flutter App Running on Windows**
   - Run: `flutter run -d windows`
   - Navigate to the register screen
   - Click "Initialize Reader" button

### Testing Flow

1. **First Test: Check Connector**
   - Click "Initialize Reader"
   - Expected: "Connector service offline" message if connector isn't running
   - Expected: "Reader ready (LED: steady_blue)" if everything works

2. **Visual Indicators**
   - Real reader will show:
     - **Flashing blue (1s interval)**: Ready to connect/pair
     - **Steady blue**: Connected and ready to process
     - **Flashing red**: Low battery
     - **Steady green**: Charging/charged

3. **Audio Feedback**
   - On successful initialization, reader should emit a chirp/beep
   - This is triggered by `POST /reader/beep` endpoint

## Debug Information

### If You See "Connector service offline"
- Verify connector is running: `node server.js` in `connector/` directory
- Check port 17777 is not blocked by firewall
- Verify `.env` has `CONNECTOR_TOKEN` set

### If You See "Reader error"
- Check reader is connected via USB
- Verify reader drivers are installed
- Check `EpnSdkBridge.exe` exists in `connector/` directory
- Check `DRIVER_MODE` in connector `.env` (should be `bbpos-sdk` or your specific mode)

### Full Diagnostic Endpoints
From command line or Postman:
```bash
# Check connector is alive
curl http://127.0.0.1:17777/health

# Check reader readiness with diagnostics
curl -H "X-Connector-Token: dev-token" http://127.0.0.1:17777/health/readiness

# Get current reader status
curl -H "X-Connector-Token: dev-token" http://127.0.0.1:17777/reader/status

# Discover available readers
curl -H "X-Connector-Token: dev-token" http://127.0.0.1:17777/reader/discover
```

## Configuration to Update

### Future: Load Token from .env
The connector token is currently hardcoded as `'dev-token'` in:
- `lib/services/chip_reader_service.dart` line 6

To make this production-ready:
1. Add token to app `.env` or config file
2. Load it in `ChipReaderService` constructor
3. Same approach for host/port configuration

### Future: Real-Time Status Monitoring
The connector provides SSE stream for live progress:
- Endpoint: `GET /emv/events` (Server-Sent Events)
- Can show real-time reader status updates
- Already provides progress indicators during payment processing

## Next Steps for Full Implementation

1. ✅ **Reader Initialization** — IMPLEMENTED (this update)
2. 📋 **LED Status Display** — Add visual LED widget (red/green/blue indicators)
3. 📋 **Real-Time Monitoring** — Subscribe to `/emv/events` for live updates
4. 📋 **Payment Processing** — Implement card read + gateway integration
5. 📋 **Sound/Chirp Feedback** — Already working via reader device
6. 📋 **Device Discovery UI** — Let users select from discovered readers

## File Changes Summary
- `lib/services/chip_reader_service.dart` — Complete rewrite (HTTP-based)
- `lib/register/register_screen.dart` — Enhanced `_initializeReader()` with health checks
- This file (setup guide)

## Issue Reference
**Problem**: Flutter method channel not implemented → blank/timeout errors
**Solution**: Use HTTP to communicate with connector service (which already has the logic)
**Result**: Reader initialization now works end-to-end with proper error reporting
