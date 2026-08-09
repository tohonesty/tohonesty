"use strict";

(() => {
    const PROTOCOL = "TOHONESTY-INTAKE-V1";
    const KEY_URL = "/assets/crypto/public-key.json";
    const API_URL = "/api/contact";

    const MAX_NAME_LENGTH = 150;
    const MAX_EMAIL_LENGTH = 254;
    const MAX_SELECTION_LENGTH = 300;

    let publicKey = null;
    let keyId = null;

    function bytesToBase64Url(bytes) {
        let binary = "";

        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }

        return btoa(binary)
            .replace(/\+/g, "-")
            .replace(/\//g, "_")
            .replace(/=+$/g, "");
    }

    function objectToOpaqueString(object) {
        const json = JSON.stringify(object);
        const bytes = new TextEncoder().encode(json);

        return bytesToBase64Url(bytes);
    }

    async function loadPublicKey() {
        const response = await fetch(KEY_URL, {
            method: "GET",
            cache: "no-store",
            credentials: "omit"
        });

        if (!response.ok) {
            throw new Error("Public key unavailable.");
        }

        const keyFile = await response.json();

        if (
            !keyFile ||
            typeof keyFile.kid !== "string" ||
            !keyFile.jwk ||
            keyFile.jwk.kty !== "RSA" ||
            keyFile.jwk.alg !== "RSA-OAEP-256"
        ) {
            throw new Error("Invalid public-key configuration.");
        }

        const importedKey = await crypto.subtle.importKey(
            "jwk",
            keyFile.jwk,
            {
                name: "RSA-OAEP",
                hash: "SHA-256"
            },
            false,
            ["encrypt"]
        );

        if (
            importedKey.algorithm.name !== "RSA-OAEP" ||
            importedKey.algorithm.hash.name !== "SHA-256" ||
            importedKey.algorithm.modulusLength < 2048
        ) {
            throw new Error("Public key does not meet security policy.");
        }

        publicKey = importedKey;
        keyId = keyFile.kid;
    }

    function validateField(element, maxLength) {
        if (!element) {
            throw new Error("Required form field missing.");
        }

        if (!element.checkValidity()) {
            element.reportValidity();
            return false;
        }

        if (element.value.length > maxLength) {
            element.setCustomValidity("This value is too long.");
            element.reportValidity();
            element.setCustomValidity("");
            return false;
        }

        return true;
    }

    async function encryptSubmission(plaintext) {
        const plaintextBytes = new TextEncoder().encode(plaintext);

        const aesKey = await crypto.subtle.generateKey(
            {
                name: "AES-GCM",
                length: 256
            },
            true,
            ["encrypt"]
        );

        const iv = crypto.getRandomValues(new Uint8Array(12));

        /*
         * Bind protocol version and monthly key ID to the
         * authenticated encryption operation.
         */
        const aadText = `${PROTOCOL}|${keyId}`;
        const aad = new TextEncoder().encode(aadText);

        try {
            const encryptedPayload = await crypto.subtle.encrypt(
                {
                    name: "AES-GCM",
                    iv,
                    additionalData: aad,
                    tagLength: 128
                },
                aesKey,
                plaintextBytes
            );

            const rawAesKey = await crypto.subtle.exportKey(
                "raw",
                aesKey
            );

            const encryptedAesKey = await crypto.subtle.encrypt(
                {
                    name: "RSA-OAEP"
                },
                publicKey,
                rawAesKey
            );

            /*
             * The envelope itself contains no client plaintext.
             */
            const envelope = {
                v: 1,
                kid: keyId,
                alg: "RSA-OAEP-256+A256GCM",
                iv: bytesToBase64Url(new Uint8Array(iv)),
                ek: bytesToBase64Url(new Uint8Array(encryptedAesKey)),
                ct: bytesToBase64Url(new Uint8Array(encryptedPayload))
            };

            return objectToOpaqueString(envelope);
        } finally {
            /*
             * JavaScript cannot guarantee physical memory erasure,
             * but mutable byte buffers can still be cleared promptly.
             */
            plaintextBytes.fill(0);
            aad.fill(0);
        }
    }

    async function submitEncrypted() {
        const button = document.getElementById("tohonesty-submit");

        const name = document.getElementById("form-field-name");
        const email = document.getElementById("form-field-email");
        const selection =
            document.getElementById("form-field-field_3ba06fe");
        const consent =
            document.getElementById("form-field-field_79c1e0c");

        if (
            !validateField(name, MAX_NAME_LENGTH) ||
            !validateField(email, MAX_EMAIL_LENGTH) ||
            !validateField(selection, MAX_SELECTION_LENGTH)
        ) {
            return;
        }

        if (!consent || !consent.checked) {
            consent?.reportValidity();
            return;
        }

        if (!publicKey || !keyId) {
            window.alert(
                "Secure submission is temporarily unavailable. " +
                "Please try again later."
            );
            return;
        }

        button.disabled = true;

        /*
         * This plaintext exists only in browser memory.
         * It is never supplied to fetch(), URL parameters,
         * browser storage, logging or analytics.
         */
        let plaintext =
            `${PROTOCOL}\n` +
            `KEY-ID: ${keyId}\n\n` +
            `Full Name: ${name.value.trim()}\n` +
            `Email: ${email.value.trim()}\n` +
            `Selection: ${selection.value}\n` +
            `Consent: Client checked the mandatory consent box.`;

        try {
            const ciphertext = await encryptSubmission(plaintext);

            /*
             * Encryption succeeded. Remove visible plaintext from
             * the DOM before making the network request.
             */
            name.value = "";
            email.value = "";
            selection.selectedIndex = -1;
            consent.checked = false;

            /*
             * Remove our last explicit string reference.
             */
            plaintext = "";

            const response = await fetch(API_URL, {
                method: "POST",
                credentials: "omit",
                cache: "no-store",
                redirect: "error",
                referrerPolicy: "no-referrer",
                headers: {
                    "Content-Type": "application/json"
                },
                body: JSON.stringify({
                    ciphertext
                })
            });

            if (!response.ok) {
                throw new Error("Submission failed.");
            }

            window.alert(
                "Your secure enquiry has been submitted successfully."
            );

        } catch {
            /*
             * Deliberately do not log the exception.
             */
            window.alert(
                "The secure submission could not be completed. " +
                "Please re-enter your details and try again."
            );
        } finally {
            plaintext = "";
            button.disabled = false;
        }
    }

    async function initialise() {
        const button = document.getElementById("tohonesty-submit");

        if (!button || !window.crypto?.subtle) {
            return;
        }

        /*
         * Fail closed while the encryption key is unavailable.
         */
        button.disabled = true;

        try {
            await loadPublicKey();
            button.disabled = false;
        } catch {
            /*
             * No console logging and no fallback plaintext path.
             */
            button.disabled = true;
        }

        button.addEventListener("click", submitEncrypted);
    }

    if (document.readyState === "loading") {
        document.addEventListener(
            "DOMContentLoaded",
            initialise,
            { once: true }
        );
    } else {
        initialise();
    }
})();
