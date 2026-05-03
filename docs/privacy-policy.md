# Privacy Policy for Kanade

**Last updated: May 3, 2026**

Kanade ("we", "our", or "the app") is a native iOS and macOS client for [kanade](https://github.com/petitstrawberry/kanade), a self-hosted music system. This privacy policy describes how the app handles your information.

## Data Collection

**Kanade does not collect, store, or transmit any personal data to us.**

Specifically, Kanade:

- Does **not** require an account or registration
- Does **not** collect personal information (name, email, device ID, etc.)
- Does **not** use analytics or tracking services
- Does **not** serve advertisements
- Does **not** collect usage statistics or crash reports

## Network Communication

Kanade communicates exclusively with [kanade servers](https://github.com/petitstrawberry/kanade) that you configure yourself:

- **Local network discovery** — The app uses Bonjour (mDNS) to discover kanade servers on your local network. This broadcasts a query for the `_kanade._tcp` service type.
- **Server connection** — The app connects to kanade servers via WebSocket and HTTP to stream music and control playback. All communication is between your device and your own server.
- **Local playback** — Audio streams are delivered via HLS directly to your device.

No data is sent to any third-party service or to the app developer.

## Security

Kanade supports secure connections:

- **TLS** — Connect to your server over `wss://` for encrypted communication.
- **mTLS** — Client certificate authentication for environments that require it.
- **Custom CA** — Trust your own certificate authority for self-signed certificates.

## Data Storage

All app data (server connections, preferences, playback state) is stored locally on your device. No data leaves your device except to your own configured kanade server.

## Third-Party Services

Kanade does not integrate with any third-party services, SDKs, or frameworks that collect user data.

## Children's Privacy

Kanade does not knowingly collect information from children. Since no personal data is collected at all, the app is suitable for users of all ages.

## Changes to This Policy

We may update this privacy policy from time to time. Any changes will be reflected on this page with an updated date.

## Contact

For questions about this privacy policy, please open an issue on the [GitHub repository](https://github.com/petitstrawberry/KanadeApp).
