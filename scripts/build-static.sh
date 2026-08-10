#!/usr/bin/env bash

set -euo pipefail

SOURCE="${1:-}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${PROJECT_ROOT}/dist"

if [[ -z "$SOURCE" ]]; then
    echo "Usage: $0 /path/to/static-build"
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory does not exist:"
    echo "$SOURCE"
    exit 1
fi

if [[ ! -f "$SOURCE/index.html" ]]; then
    echo "ERROR: Source does not look like a Tohonesty wget export."
    echo "Missing index.html"
    exit 1
fi

echo "Source:"
echo "  $SOURCE"
echo
echo "Destination:"
echo "  $DIST"
echo


#
# -------------------------------------------------------------------
# 1. REBUILD DIST FROM SCRATCH
# -------------------------------------------------------------------
#

rm -rf "$DIST"
mkdir -p "$DIST"

rsync -a \
    --exclude='.DS_Store' \
    "$SOURCE/" "$DIST/"


#
# -------------------------------------------------------------------
# 2. REMOVE WORDPRESS SERVER/RUNTIME ENDPOINTS
# -------------------------------------------------------------------
#

rm -rf \
    "$DIST/comments" \
    "$DIST/feed" \
    "$DIST/wp-json"

rm -f \
    "$DIST/xmlrpc.php?rsd"

find "$DIST" \
    -maxdepth 1 \
    -type f \
    -name 'index.html?p=*.html' \
    -delete


#
# -------------------------------------------------------------------
# 3. GENERAL HTML CLEANUP
# -------------------------------------------------------------------
#

python3 - "$DIST" <<'PY'
from pathlib import Path
import re
import sys

dist = Path(sys.argv[1])


def remove_old_crypto_script(match):
    script = match.group(0)

    if (
        "TOHONESTY_PUBLIC_KEY" in script
        or "SECURE_TRANSMISSION_ACTIVE" in script
    ):
        return ""

    return script


for path in list(dist.rglob("*.html")):
    text = path.read_text(encoding="utf-8")

    text = re.sub(
        r'<link[^>]+type=["\']application/json\+oembed["\'][^>]*>\s*',
        '',
        text,
        flags=re.I
    )

    text = re.sub(
        r'<link[^>]+type=["\']text/xml\+oembed["\'][^>]*>\s*',
        '',
        text,
        flags=re.I
    )

    text = re.sub(
        r'<link[^>]+rel=["\']https://api\.w\.org/["\'][^>]*>\s*',
        '',
        text,
        flags=re.I
    )

    text = re.sub(
        r'<link[^>]+type=["\']application/json["\'][^>]+wp-json[^>]*>\s*',
        '',
        text,
        flags=re.I
    )

    text = re.sub(
        r'<link[^>]+rel=["\']EditURI["\'][^>]*>\s*',
        '',
        text,
        flags=re.I
    )

    text = re.sub(
        r'<script\b(?![^>]*\bsrc=)[^>]*>'
        r'(?:(?!</script>).)*'
        r'</script>',
        remove_old_crypto_script,
        text,
        flags=re.I | re.S
    )

    text = re.sub(
        r'<script[^>]+type=["\']speculationrules["\'][^>]*>'
        r'(?:(?!</script>).)*'
        r'</script>',
        '',
        text,
        flags=re.I | re.S
    )

    text = re.sub(
        r'<script[^>]+id=["\']wp-emoji-settings["\'][^>]*>'
        r'(?:(?!</script>).)*'
        r'</script>',
        '',
        text,
        flags=re.I | re.S
    )

    text = re.sub(
        r'<script[^>]+type=["\']module["\'][^>]*>'
        r'(?:(?!</script>).)*'
        r'wpEmojiSettingsSupports'
        r'(?:(?!</script>).)*'
        r'</script>',
        '',
        text,
        flags=re.I | re.S
    )

    #
    # Convert Local hostname to production hostname.
    #
    text = text.replace(
        'http://tohonesty.local',
        'https://tohonesty.com'
    )

    text = text.replace(
        'http:\\/\\/tohonesty.local',
        'https:\\/\\/tohonesty.com'
    )

    text = text.replace(
        '@tohonesty.local',
        '@tohonesty.com'
    )

    #
    # Neutralise WordPress backend URLs embedded in Elementor config.
    #
    text = text.replace(
        'https:\\/\\/tohonesty.com\\/wp-admin\\/admin-ajax.php',
        ''
    )

    text = text.replace(
        'https:\\/\\/tohonesty.com\\/wp-json\\/',
        ''
    )

    text = text.replace(
        'https://tohonesty.com/wp-admin/admin-ajax.php',
        ''
    )

    text = text.replace(
        'https://tohonesty.com/wp-json/',
        ''
    )

    #
    # Convert old WordPress query-style links.
    #
    page_map = {
        "1134": "/tohonesty-ltd-privacy-policy",
        "1142": "/tohonesty-ltd-client-terms-of-business/",
        "1145": "/tohonesty-ltd-website-terms-of-use",
        "1254": "/legal-disclosure",
        "1415": "/contact-form/",
        "23":   "/about/",
        "66":   "/faqs/",
    }

    for post_id, url in page_map.items():
        variants = (
            f"index.html%3Fp={post_id}.html",
            f"index.html?p={post_id}.html",
        )

        for old in variants:
            text = text.replace(old, url)

    text = text.replace(
        "contact-form.html",
        "/contact-form/"
    )

    path.write_text(text, encoding="utf-8")


#
# -------------------------------------------------------------------
# 4. PREPARE CONTACT PAGE BEFORE MOVING IT
# -------------------------------------------------------------------
#

old_contact = dist / "contact-form.html"

if not old_contact.exists():
    raise RuntimeError(
        "Expected contact-form.html was not present in wget output."
    )

text = old_contact.read_text(encoding="utf-8")

#
# Make WordPress static asset paths site-root absolute before moving
# the page under /contact-form/.
#
text = re.sub(
    r'((?:href|src)=["\'])wp-content/',
    r'\1/wp-content/',
    text,
    flags=re.I
)

text = re.sub(
    r'((?:href|src)=["\'])wp-includes/',
    r'\1/wp-includes/',
    text,
    flags=re.I
)

text = text.replace(
    'url(wp-content/',
    'url(/wp-content/'
)

text = text.replace(
    "url('wp-content/",
    "url('/wp-content/"
)

text = text.replace(
    'url("wp-content/',
    'url("/wp-content/'
)

text = text.replace(
    'url(wp-includes/',
    'url(/wp-includes/'
)

text = text.replace(
    "url('wp-includes/",
    "url('/wp-includes/"
)

text = text.replace(
    'url("wp-includes/',
    'url("/wp-includes/'
)


#
# -------------------------------------------------------------------
# 5. HARDEN CONTACT FORM - FAIL CLOSED
# -------------------------------------------------------------------
#

text = re.sub(
    r'<input\b[^>]*\btype=["\']hidden["\'][^>]*>',
    '',
    text,
    flags=re.I
)

text, count = re.subn(
    r'<form\b[^>]*\bclass=["\'][^"\']*\belementor-form\b[^"\']*["\'][^>]*>',
    '<div id="tohonesty-intake" '
    'class="elementor-form" '
    'role="form" '
    'aria-label="Secure case intake">',
    text,
    count=1,
    flags=re.I
)

if count != 1:
    raise RuntimeError(
        f"Expected exactly one Elementor form opening tag; found {count}"
    )

text, count = re.subn(
    r'</form\s*>',
    '</div>',
    text,
    count=1,
    flags=re.I
)

if count != 1:
    raise RuntimeError(
        f"Expected exactly one closing form tag; found {count}"
    )

text, count = re.subn(
    r'<button\b([^>]*?)\btype=["\']submit["\']([^>]*)>',
    r'<button\1type="button"\2 id="tohonesty-submit">',
    text,
    count=1,
    flags=re.I
)

if count != 1:
    raise RuntimeError(
        f"Expected exactly one submit button; found {count}"
    )

if "/assets/js/contact.js" not in text:
    text, count = re.subn(
        r'</body\s*>',
        '<script src="/assets/js/contact.js" defer></script>\n</body>',
        text,
        count=1,
        flags=re.I
    )

    if count != 1:
        raise RuntimeError(
            "Could not insert contact.js before </body>"
        )

old_contact.write_text(text, encoding="utf-8")


#
# -------------------------------------------------------------------
# 6. MOVE CONTACT PAGE TO /contact-form/
# -------------------------------------------------------------------
#

new_contact_dir = dist / "contact-form"
new_contact_dir.mkdir(exist_ok=True)

new_contact_page = new_contact_dir / "index.html"

old_contact.rename(new_contact_page)


#
# -------------------------------------------------------------------
# 7. SANITY CHECK CONTACT ASSET PATHS
# -------------------------------------------------------------------
#

text = new_contact_page.read_text(encoding="utf-8")

bad_relative_assets = re.findall(
    r'(?:href|src)=["\'](?:wp-content|wp-includes)/',
    text,
    flags=re.I
)

if bad_relative_assets:
    raise RuntimeError(
        "Contact page still contains relative WordPress asset paths."
    )

new_contact_page.write_text(text, encoding="utf-8")

PY


#
# -------------------------------------------------------------------
# 8. NORMALISE STATIC CSS ASSET URLS
# -------------------------------------------------------------------
#

python3 - "$DIST" <<'PY'
from pathlib import Path
import sys

dist = Path(sys.argv[1])

for path in dist.rglob("*.css"):
    text = path.read_text(
        encoding="utf-8",
        errors="replace"
    )

    replacements = {
        "https://www.tohonesty.com/wp-content/":
            "/wp-content/",

        "https://tohonesty.com/wp-content/":
            "/wp-content/",

        "http://www.tohonesty.com/wp-content/":
            "/wp-content/",

        "http://tohonesty.com/wp-content/":
            "/wp-content/",

        "http://tohonesty.local/wp-content/":
            "/wp-content/"
    }

    for old, new in replacements.items():
        text = text.replace(old, new)

    path.write_text(text, encoding="utf-8")
PY


CSS_REMOTE_REFS="$(
    grep -RInE \
      --include='*.css' \
      'https?://(www\.)?tohonesty\.(com|local)/wp-content/' \
      "$DIST" || true
)"

if [[ -n "$CSS_REMOTE_REFS" ]]; then
    echo
    echo "ERROR: Absolute Tohonesty asset URLs remain in CSS:"
    echo "$CSS_REMOTE_REFS"
    exit 1
fi

echo "Static CSS asset URLs normalized."


#
# -------------------------------------------------------------------
# 9. COPY ELEMENTOR LOCAL FONT FILES
# -------------------------------------------------------------------
#

#
# SOURCE:
#   ~/Local Sites/tohonesty/app/public/public_static/static-build
#
# Original Local WP public directory:
#   ~/Local Sites/tohonesty/app/public
#
LOCAL_PUBLIC="$(cd "$SOURCE/../.." && pwd)"

LOCAL_FONT_DIR="$LOCAL_PUBLIC/wp-content/uploads/elementor/google-fonts/fonts"
DIST_FONT_DIR="$DIST/wp-content/uploads/elementor/google-fonts/fonts"

if [[ ! -d "$LOCAL_FONT_DIR" ]]; then
    echo
    echo "ERROR: Elementor local font directory not found:"
    echo "$LOCAL_FONT_DIR"
    exit 1
fi

mkdir -p "$DIST_FONT_DIR"

rsync -a \
    "$LOCAL_FONT_DIR/" \
    "$DIST_FONT_DIR/"

FONT_COUNT="$(
    find "$DIST_FONT_DIR" -type f 2>/dev/null \
        | grep -Ei '\.woff2?$' \
        | wc -l \
        | tr -d ' '
)"

if [[ "$FONT_COUNT" -eq 0 ]]; then
    echo
    echo "ERROR: No WOFF/WOFF2 Elementor font files were copied."
    exit 1
fi

echo "Copied $FONT_COUNT locally hosted font files."


#
# -------------------------------------------------------------------
# 10. COPY ASSETS OWNED BY US
# -------------------------------------------------------------------
#

mkdir -p "$DIST/assets"

rsync -a \
    "$PROJECT_ROOT/site/assets/" \
    "$DIST/assets/"


#
# Copy Cloudflare Static Assets response-header rules.
#
cp \
    "$PROJECT_ROOT/site/_headers" \
    "$DIST/_headers"

#
# -------------------------------------------------------------------
# 11. BLOCK SENSITIVE FILES
# -------------------------------------------------------------------
#

BAD_FILES="$(
    find "$DIST" -type f \
        \( -name '.env' \
        -o -name '*.pem' \
        -o -name '*.key' \
        -o -name '*.p12' \
        -o -name '*.pfx' \
        -o -name 'wp-config.php' \
        -o -name '*.sql' \
        \) -print
)"

if [[ -n "$BAD_FILES" ]]; then
    echo
    echo "ERROR: Potentially sensitive files found:"
    echo "$BAD_FILES"
    exit 1
fi


#
# -------------------------------------------------------------------
# 12. CHECK FOR FORBIDDEN WORDPRESS/LOCAL REFERENCES
# -------------------------------------------------------------------
#

echo
echo "Checking cleaned site..."

PROBLEMS="$(
    grep -RInE \
      --include='*.html' \
      --include='*.js' \
      --include='*.css' \
      '(tohonesty\.local|wp-json|xmlrpc\.php|admin-ajax\.php|SECURE_TRANSMISSION_ACTIVE|TOHONESTY_PUBLIC_KEY|\?p=[0-9]+)' \
      "$DIST" || true
)"

if [[ -n "$PROBLEMS" ]]; then
    echo
    echo "ERROR: Forbidden WordPress/Local references remain:"
    echo "$PROBLEMS"
    exit 1
fi

echo "No forbidden WordPress/Local references found."


#
# -------------------------------------------------------------------
# 13. CONTACT FORM SECURITY ASSERTIONS
# -------------------------------------------------------------------
#

CONTACT_PAGE="$DIST/contact-form/index.html"

if grep -Eqi '<form\b|</form>' "$CONTACT_PAGE"; then
    echo
    echo "ERROR: Native HTML form remains in contact page."
    exit 1
fi

if grep -Eqi 'type=["'\'']hidden["'\'']' "$CONTACT_PAGE"; then
    echo
    echo "ERROR: Hidden Elementor submission fields remain."
    exit 1
fi

if ! grep -q 'id="tohonesty-intake"' "$CONTACT_PAGE"; then
    echo
    echo "ERROR: Secure intake container not found."
    exit 1
fi

if ! grep -q 'id="tohonesty-submit"' "$CONTACT_PAGE"; then
    echo
    echo "ERROR: Secure submission button not found."
    exit 1
fi

if ! grep -q '/assets/js/contact.js' "$CONTACT_PAGE"; then
    echo
    echo "ERROR: Secure contact handler not loaded."
    exit 1
fi

if [[ ! -f "$DIST/assets/js/contact.js" ]]; then
    echo
    echo "ERROR: contact.js missing from dist."
    exit 1
fi

if [[ ! -f "$DIST/assets/crypto/public-key.json" ]]; then
    echo
    echo "ERROR: public-key.json missing from dist."
    exit 1
fi

if grep -Eqi \
    '(href|src)=["'\''](wp-content|wp-includes)/' \
    "$CONTACT_PAGE"; then

    echo
    echo "ERROR: Contact page contains broken relative asset paths."
    exit 1
fi

echo "Contact form security checks passed."


#
# -------------------------------------------------------------------
# 14. FONT DEPLOYMENT ASSERTIONS
# -------------------------------------------------------------------
#

FONT_FILE_COUNT="$(
    find "$DIST_FONT_DIR" -type f 2>/dev/null \
        | grep -Ei '\.woff2?$' \
        | wc -l \
        | tr -d ' '
)"

if [[ "$FONT_FILE_COUNT" -eq 0 ]]; then
    echo
    echo "ERROR: No WOFF/WOFF2 fonts found in deployment."
    exit 1
fi

echo "Found $FONT_FILE_COUNT deployed font files."

REQUIRED_FONTS=(
    "opensans-memvyags126mizpba-uvwbx2vvnxbbobj2ovts-muw.woff2"
    "roboto-kfo7cnqeu92fr1me7ksn66agldtyluama3yuba.woff2"
    "roboto-kfo7cnqeu92fr1me7ksn66agldtyluamaxkubgee.woff2"
)

for font in "${REQUIRED_FONTS[@]}"; do
    if [[ ! -f "$DIST_FONT_DIR/$font" ]]; then
        echo
        echo "ERROR: Required font missing from deployment:"
        echo "$font"
        exit 1
    fi
done

echo "Font deployment checks passed."

if [[ ! -f "$DIST/_headers" ]]; then
    echo
    echo "ERROR: Cloudflare _headers file missing from dist."
    exit 1
fi

echo "Cloudflare security headers present."

#
# -------------------------------------------------------------------
# 15. FINAL INVENTORY
# -------------------------------------------------------------------
#

echo
echo "Build complete."

FILE_COUNT="$(
    find "$DIST" -type f \
        | wc -l \
        | tr -d ' '
)"

BUILD_SIZE="$(
    du -sh "$DIST" \
        | awk '{print $1}'
)"

echo "Files:  $FILE_COUNT"
echo "Size:   $BUILD_SIZE"
echo "Output: $DIST"