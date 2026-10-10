DJOneHub for Windows amd64
==========================

Install
-------
1. Extract the complete ZIP archive.
2. Double-click "Install DJOneHub.cmd".
3. Connect the DJI first-generation 4G module and install its Windows serial
   driver if Windows does not expose a COM port.

Current Windows boundary
------------------------
- DJOneHub.exe is a Windows amd64 cross-build. It has not been validated on a
  real Windows PC with this module, so no module function is promised yet.
- When the module exposes a usable Windows COM port, the intended control
  surface is status, AT control, SMS, GPS queries, call-state control and the
  local control panel.
- Not included: module-side voice runtime, bidirectional call audio, direct
  vendor USB AT/eSIM, automatic USB network policy, macOS notifications,
  Contacts and MapKit.
- Built on macOS by cross-compilation; Windows hardware validation remains a
  required follow-up before a functional release claim.

DJOneHub is an unofficial third-party project and is not affiliated with DJI,
Quectel, carriers or eSIM vendors.
