"use strict";

const API_PATH = "/api/contact";

const EXPECTED_VERSION = 1;
const EXPECTED_ALGORITHM = "RSA-OAEP-256+A256GCM";

/*
 * Generous enough for the encrypted intake envelope,
 * while small enough to reject abusive payloads early.
 */
const MAX_REQUEST_BYTES = 12 * 1024;
const MAX_CIPHERTEXT_STRING_LENGTH = 8192;

/*
 * Current key. Update this at monthly key rotation.
 *
 * This is not secret; it is used only to reject obsolete or
 * unexpected encryption envelopes.
 */
const ACCEPTED_KEY_IDS = new Set([
    "2026-08"
]);

const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

const NO_STORE_HEADERS = {
    "Cache-Control": "no-store, max-age=0",
    "Pragma": "no-cache",
    "X-Content-Type-Options": "nosniff"
};

function emptyResponse(status) {
    return new Response(null, {
        status,
        headers: NO_STORE_HEADERS
    });
}

function base64UrlToBytes(value) {
    if (
        typeof value !== "string" ||
        value.length === 0 ||
        !BASE64URL_RE.test(value)
    ) {
        throw new Error("Invalid Base64URL.");
    }

    let base64 = value
        .replace(/-/g, "+")
        .replace(/_/g, "/");

    const remainder = base64.length % 4;

    if (remainder === 2) {
        base64 += "==";
    } else if (remainder === 3) {
        base64 += "=";
    } else if (remainder !== 0) {
        throw new Error("Invalid Base64URL length.");
    }

    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);

    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }

    return bytes;
}

function decodeOuterEnvelope(ciphertextString) {
    const bytes = base64UrlToBytes(ciphertextString);

    /*
     * The outer envelope contains only cryptographic metadata
     * and encrypted material — never client plaintext.
     */
    const json = new TextDecoder("utf-8", {
        fatal: true
    }).decode(bytes);

    return JSON.parse(json);
}

function validateEnvelope(ciphertextString) {
    if (
        typeof ciphertextString !== "string" ||
        ciphertextString.length < 100 ||
        ciphertextString.length > MAX_CIPHERTEXT_STRING_LENGTH ||
        !BASE64URL_RE.test(ciphertextString)
    ) {
        return false;
    }

    let envelope;

    try {
        envelope = decodeOuterEnvelope(ciphertextString);
    } catch {
        return false;
    }

    if (
        !envelope ||
        typeof envelope !== "object" ||
        Array.isArray(envelope)
    ) {
        return false;
    }

    /*
     * Accept exactly these five fields.
     */
    const keys = Object.keys(envelope).sort();

    const expectedKeys = [
        "alg",
        "ct",
        "ek",
        "iv",
        "kid",
        "v"
    ].sort();

    if (
        keys.length !== expectedKeys.length ||
        !keys.every((key, index) => key === expectedKeys[index])
    ) {
        return false;
    }

    if (envelope.v !== EXPECTED_VERSION) {
        return false;
    }

    if (envelope.alg !== EXPECTED_ALGORITHM) {
        return false;
    }

    if (
        typeof envelope.kid !== "string" ||
        !ACCEPTED_KEY_IDS.has(envelope.kid)
    ) {
        return false;
    }

    /*
     * AES-GCM IV is exactly 96 bits = 12 bytes.
     */
    let iv;

    try {
        iv = base64UrlToBytes(envelope.iv);
    } catch {
        return false;
    }

    if (iv.byteLength !== 12) {
        return false;
    }

    /*
     * Your current RSA key is 2048 bits, so the RSA-OAEP
     * encrypted AES key must be exactly 256 bytes.
     *
     * Change this to 384 when you rotate to RSA-3072.
     */
    let encryptedKey;

    try {
        encryptedKey = base64UrlToBytes(envelope.ek);
    } catch {
        return false;
    }

    if (encryptedKey.byteLength !== 256) {
        return false;
    }

    /*
     * AES-GCM output includes the authentication tag.
     *
     * Require a plausible encrypted body, but don't attempt
     * to interpret or decrypt it.
     */
    let encryptedPayload;

    try {
        encryptedPayload = base64UrlToBytes(envelope.ct);
    } catch {
        return false;
    }

    if (
        encryptedPayload.byteLength < 32 ||
        encryptedPayload.byteLength > 4096
    ) {
        return false;
    }

    return true;
}

function requestHasCorrectOrigin(request, url) {
    const origin = request.headers.get("Origin");

    /*
     * Browser POSTs from our site should always have Origin.
     * Requiring same-origin also works on workers.dev previews,
     * because url.origin changes with the preview hostname.
     */
    return origin === url.origin;
}

async function handleContact(request, env) {
    /*
     * POST only.
     */
    if (request.method !== "POST") {
        return emptyResponse(405);
    }

    const url = new URL(request.url);

    /*
     * Require same-origin browser submission.
     */
    if (!requestHasCorrectOrigin(request, url)) {
        return emptyResponse(403);
    }

    /*
     * An additional browser-origin signal.
     *
     * Don't depend on this alone; Origin above is authoritative
     * for our application.
     */
    const fetchSite = request.headers.get("Sec-Fetch-Site");

    if (fetchSite && fetchSite !== "same-origin") {
        return emptyResponse(403);
    }

    /*
     * Require JSON.
     */
    const contentType = request.headers.get("Content-Type") || "";

    if (
        !contentType
            .toLowerCase()
            .startsWith("application/json")
    ) {
        return emptyResponse(415);
    }

    /*
     * Reject obviously oversized requests before reading them
     * when Content-Length is available.
     */
    const contentLength =
        Number(request.headers.get("Content-Length"));

    if (
        Number.isFinite(contentLength) &&
        contentLength > MAX_REQUEST_BYTES
    ) {
        return emptyResponse(413);
    }

    let rawBody;

    try {
        rawBody = await request.text();
    } catch {
        return emptyResponse(400);
    }

    if (
        rawBody.length === 0 ||
        rawBody.length > MAX_REQUEST_BYTES
    ) {
        return emptyResponse(
            rawBody.length > MAX_REQUEST_BYTES ? 413 : 400
        );
    }

    let body;

    try {
        body = JSON.parse(rawBody);
    } catch {
        return emptyResponse(400);
    }

    /*
     * Require exactly:
     *
     * {
     *   "ciphertext": "..."
     * }
     */
    if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body)
    ) {
        return emptyResponse(400);
    }

    const bodyKeys = Object.keys(body);

    if (
        bodyKeys.length !== 1 ||
        bodyKeys[0] !== "ciphertext"
    ) {
        return emptyResponse(400);
    }

    if (!validateEnvelope(body.ciphertext)) {
        return emptyResponse(400);
    }

    const emailBody =
        "New High-Value Case Intake Notification\n\n" +
        "Encrypted client submission:\n\n" +
        "-----BEGIN TOHONESTY CIPHERTEXT-----\n" +
        body.ciphertext +
        "\n-----END TOHONESTY CIPHERTEXT-----\n";

    try {
        /*
         * We deliberately:
         *
         * - do not log the request
         * - do not log ciphertext
         * - do not return the Email Service message ID
         * - do not store anything
         */
        await env.INTAKE_EMAIL.send({
            to: "tohonesty@tohonesty.com",

            from: {
                email: "tohonesty@tohonesty.com",
                name: "Tohonesty Intake"
            },

            subject:
                "New High-Value Case Intake Notification",

            text: emailBody
        });

        return emptyResponse(204);

    } catch {
        /*
         * Deliberately do not console.log() the error.
         *
         * The browser learns only that delivery failed.
         */
        return emptyResponse(503);
    }
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        /*
         * The Worker has only one application endpoint.
         */
        if (url.pathname !== API_PATH) {
            return emptyResponse(404);
        }

        return handleContact(request, env);
    }
};
