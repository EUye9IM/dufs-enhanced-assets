// Fetched by detectCertificateTrust() in index.js. Registering this file is the only
// same-origin way to find out whether the browser trusts the server certificate:
// the service worker script fetch ignores the click-through exception that normal
// subresources get. It never handles a request.
self.addEventListener("install", () => self.skipWaiting());
