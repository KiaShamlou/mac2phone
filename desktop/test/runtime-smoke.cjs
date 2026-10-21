'use strict';
const assert=require('node:assert/strict');
const tls=require('node:tls');
const {CIPHER}=require('../core/pairing.cjs');
assert.ok(process.versions.electron,'Run this test inside Electron with ELECTRON_RUN_AS_NODE=1');
assert.ok(tls.getCiphers().includes(CIPHER.toLowerCase()));
tls.createSecureContext({minVersion:'TLSv1.2',maxVersion:'TLSv1.2',ciphers:CIPHER});
console.log(`PASS Electron ${process.versions.electron}: required TLS-PSK cipher available`);
