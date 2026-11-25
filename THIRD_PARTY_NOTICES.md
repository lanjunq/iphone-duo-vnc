# Third-party notices

Duo VNC contains code ported from the following MIT-licensed projects. Only RFBSecurity uses ported code;
RFBDecoders, RFBClient, RFBMockServer, DuoVNCKit, RFBCore and rfbprobe were written from RFC 6143 / rfbproto.


## TailVNC (RFBSecurity: Apple RSA type 33, VNC auth)

Used in: `Sources/RFBSecurity/AppleRSASecurityHandler.swift` (port of `TailVNC/Core/AppleRSAAuthentication.swift`
and the type 33 framing in `TailVNC/Core/RFBClient.swift`); the VNC (type 2) key handling follows
`TailVNC/Core/VNCAuthentication.swift`.

```
MIT License

Copyright (c) 2026 TailVNC contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## RoyalVNCKit (RFBSecurity: ARD Diffie-Hellman type 30)

Used in: `Sources/RFBSecurity/ARDSecurityHandler.swift` (scheme from
`Sources/RoyalVNCKit/Protocol/SecurityTypes/AppleRemoteDesktop/`, reimplemented without dependencies).

```
MIT License

Copyright (c) 2025 Royal Apps

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
