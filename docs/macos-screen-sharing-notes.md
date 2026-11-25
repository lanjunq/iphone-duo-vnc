# Notes on talking to macOS Screen Sharing over RFB

What this project learned by testing a client against the Screen Sharing server built into macOS
(measured on macOS 27.0.1, November 2026, over loopback, with a dedicated non-admin test account).
Most of this is not in RFC 6143 or in the community `rfbproto` document. Each item says how it was
checked; items marked "not tested" are exactly that.

## Handshake

- The server greets with `RFB 003.889\n`, a version number that is not in any standard.
- It offers security types `[30, 33, 36, 2, 35]`. Type 2 (classic VNC password) only appears when
  "VNC viewers may control screen with password" is enabled in the Screen Sharing settings.
- This client answers `RFB 003.889\n` when it is going to log in with a macOS account and
  `RFB 003.008\n` otherwise, which is also what TailVNC does. A client that answers `003.008` is
  offered the same security list.

## Type 33: macOS account login (RSA + AES)

- **The security-type byte and the key request must be in the same TCP segment.** The client selects
  type 33 by sending the byte `33`, then asks for the server's public key with a 14-byte request
  (`00 00 00 0a 01 00 'RSA1' 00 00 00 00`). If the two are written separately, the server closes the
  connection without answering. A 1 ms gap is enough to trigger it; writing them together works every
  time. (Checked with delays of 0, 1, 5, 20, 50 and 100 ms.)
- The reply is a length-prefixed packet containing a DER `SubjectPublicKeyInfo` (RSA-2048, e = 65537).
- After the encrypted credentials, the server sends a 4-byte acknowledgement and then a 4-byte result.
  On failure the result is `00 00 00 01` and **no reason string follows**, unlike RFB 3.8. A client
  that waits for a reason string hangs.
- Nothing authenticates the server's key. This client pins its SHA-256 on first use and refuses a
  different key later. Only the login is encrypted; the session itself is plain RFB, so use it inside a
  tunnel (Tailscale, WireGuard, SSH).
- The port of the credential packaging comes from TailVNC (MIT); see `THIRD_PARTY_NOTICES.md`.

Types 30 (Apple Remote Desktop Diffie-Hellman) and 2 (VNC password) are implemented and unit-tested,
but **not tested against a real macOS server**.

## Which desktop you get

Logging in with a macOS account that is not the user at the console gives that account its own
separate virtual desktop session. To control the desktop someone is logged in to, log in as that user.

## Encodings

- Supported by the server: **ZRLE (16), Zlib (6), Raw (0)**.
- **Not supported: Tight (7), Hextile (5).** If a client advertises only those, the server sends Raw,
  so a client must always be able to decode Raw (RFC 6143 says so too).
- The Cursor pseudo-encoding (-239) was advertised but no cursor rectangle was ever received. Draw the
  pointer locally.
- A full 3840x2160 frame in ZRLE is roughly 4 to 7 MB; in Raw it is 33 MB. On loopback, with a release
  build, ServerInit arrives in about 0.17 s and the first full frame in under 1 s.

## Input

- **Input is ignored for about the first two seconds of a session.** A click sent 1.6 s after
  ServerInit did nothing; the same click at 2.2 s or later worked, every time. Keys sent in that
  window were lost as well. This client holds input in a queue until a frame has arrived and 2.5 s
  have passed.
- Pointer: "move, 80 ms, press, 60 ms, release" at a new position works reliably after that warm-up.
  This client keeps 80 ms between a button change and the pointer message before it.
- Keyboard: the server types **the character of the keysym, literally**. Uppercase letters and shifted
  symbols must be sent as their own keysyms (`A` = 0x41, `!` = 0x21). A held Shift does not change a
  letter keysym: Shift + `a` types `a`. Shift does work with non-character keys (Shift + Left selects).
- Modifier keysyms are not what an X11 user would expect:

  | macOS key | keysym |
  | --- | --- |
  | Command | `0xffeb` (Super_L); `0xffe9` (Alt_L) also acts as Command |
  | Option | `0xffe7` (Meta_L) |
  | Control | `0xffe3` (Control_L) |
  | Shift | `0xffe1` (Shift_L) |

  Checked in a text field: Meta_L + Backspace deleted one word, Alt_L + Backspace and
  Super_L + Backspace deleted the line, Control + a moved to the start of the line.
- Key timing: with 12 ms between key events, a 67-character string of mixed case, digits and symbols
  arrived correctly 8 times out of 8. With 0 to 2 ms between events the server fell more than 0.7 s
  behind; whether such bursts ever lose keys was not established. This client spaces key events by
  12 ms.

## Not tested

Clipboard in either direction, DesktopSize changes during a session, multiple displays, the lock
screen and the login window, sessions lasting more than a few minutes, and anything over a slow or
lossy network.
