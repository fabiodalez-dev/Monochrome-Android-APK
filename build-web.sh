#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# build-web.sh — Fabiodalez Music web build + deploy to music.fabiodalez.it
#
# Applies the same functional patches as build-android.sh
# (no Android-specific changes: no android-service.js, no fm-logger,
#  no brand rename, no viewport-fit).
#
# Output: dist/ directory + dist-web.zip ready for cPanel upload.
# ─────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_HOST="fabiodalez.it"
# cPanel subdomain document root (standard cPanel layout)
DEPLOY_PATH="music.fabiodalez.it"

export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"

cd "$PROJECT_DIR"

cleanup() {
    echo ""
    echo "▶ Cleaning up patched files..."
    for f in .gitignore; do
        if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            git checkout -- "$f" 2>/dev/null || true
        fi
    done
    rm -rf \
        index.html package.json package-lock.json bun.lock bun.lockb \
        vite.config.ts vite-plugin-auth-gate.js vite-plugin-blob.ts \
        vite-plugin-svg-use.ts vite-plugin-upload.js \
        styles.css stream-stub.js tsconfig.json tsconfig-eslint.json \
        eslint.config.js lhci.yml nginx.conf \
        js/ src/ public/ assets/ functions/ images/ dist/ node_modules/ \
        .npmrc .prettierrc .stylelintrc.json .htmlhintrc .gitmodules \
        .dockerignore .vscode/ .wrangler/ \
        android/build.gradle android/capacitor.settings.gradle \
        android/gradle.properties android/settings.gradle android/variables.gradle \
        android/gradlew android/gradlew.bat android/gradle/ android/.gitignore
    rm -rf node_modules/@capgo/capacitor-media-session 2>/dev/null || true
    echo "  ✓ Upstream web app files removed."
}
trap cleanup EXIT

echo "══════════════════════════════════════════"
echo "  Fabiodalez Music — Web Build"
echo "══════════════════════════════════════════"

# ── 1. Pull latest upstream ──
echo ""
echo "▶ Pulling latest from upstream/main..."
cleanup 2>/dev/null || true
git fetch upstream

UPSTREAM_SHA=$(git rev-parse upstream/main)
SYNC_FILE="$PROJECT_DIR/.upstream-sync-sha"
LAST_SHA=$(cat "$SYNC_FILE" 2>/dev/null || echo "")

if [ "$UPSTREAM_SHA" = "$LAST_SHA" ] && [ -f index.html ]; then
    echo "  Already up to date ($(git rev-parse --short upstream/main))."
    read -p "  Build anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
else
    echo "  Extracting web app from upstream/main ($(git rev-parse --short upstream/main))..."
    git archive upstream/main | tar -x \
        --exclude='capacitor.config.ts' \
        --exclude='README.md' \
        --exclude='android/' \
        --exclude='ios/' \
        --exclude='extension/' \
        --exclude='docker/' \
        --exclude='.devcontainer' \
        --exclude='.github' \
        --exclude='CONTRIBUTING.md' \
        --exclude='DOCKER.md' \
        --exclude='INSTANCES.md' \
        --exclude='THEME_GUIDE.md' \
        --exclude='license'
    echo "$UPSTREAM_SHA" > "$SYNC_FILE"
    echo "  ✓ Updated to $(git rev-parse --short upstream/main)."
fi

# ── 2. Fix upstream broken npm override ──
if grep -q '"sourcemap-codec": "\^1.4.14"' package.json; then
    sed -i '' 's|"sourcemap-codec": "\^1.4.14"|"sourcemap-codec": "^1.4.8"|' package.json
    echo "  ✓ package.json: sourcemap-codec override fixed."
fi

# ── 3. Install deps + shim media-session ──
echo ""
echo "▶ Installing dependencies..."
npm install 2>&1 | tail -3
echo "  ✓ Done."

SHIM_DIR="node_modules/@capgo/capacitor-media-session"
[ -d "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/index.js" <<'SHIMEOF'
export const MediaSession = {
    setActionHandler: async () => {},
    setMetadata: async () => {},
    setPlaybackState: async () => {},
    setPositionState: async () => {},
};
SHIMEOF
cat > "$SHIM_DIR/package.json" <<'SHIMEOF'
{"name":"@capgo/capacitor-media-session","version":"0.0.0-shim","main":"index.js","module":"index.js","type":"module"}
SHIMEOF
echo "  ✓ @capgo/capacitor-media-session shimmed."

# ── 4. Apply functional patches ──
echo ""
echo "▶ Patching upstream sources..."
python3 <<'PYEOF'
import sys, os, re

PROJECT_DIR = os.environ.get("PROJECT_DIR", os.getcwd())

def patch(path, before, after, label):
    full = os.path.join(PROJECT_DIR, path)
    with open(full, "r", encoding="utf-8") as f:
        src = f.read()
    if before not in src:
        print("  ! " + label + ": pattern not found, skipping")
        return False
    src = src.replace(before, after, 1)
    with open(full, "w", encoding="utf-8") as f:
        f.write(src)
    print("  + " + label)
    return True

# ── storage.js streaming fallback: REMOVED 2026-08-16 ──
# Upstream (41d3b9c) dropped the hardcoded instance list: INSTANCES_URLS is
# empty, the offline fallback is `api: [lol.samidy.workers.dev], streaming: []`
# and playback goes through the "unified playback" API (music-api.geeked.wtf)
# plus native TIDAL queries (HiFiClient). The old HiFi proxies are all 503/down.

# ── search debounce 3000ms → 800ms ──
patch(
    "js/app.js",
    "}, 3000);",
    "}, 800);",
    "app.js: search debounce 3000ms -> 800ms",
)

# ── enrich albums missing artist/cover from tracks ──
patch(
    "js/ui.js",
    """            if (finalAlbums.length === 0 && finalTracks.length > 0) {
                const albumMap = new Map();
                finalTracks.forEach((track) => {
                    if (track.album && !albumMap.has(track.album.id)) {
                        albumMap.set(track.album.id, track.album);
                    }
                });
                finalAlbums = Array.from(albumMap.values());
            }""",
    """            if (finalAlbums.length === 0 && finalTracks.length > 0) {
                const albumMap = new Map();
                finalTracks.forEach((track) => {
                    if (track.album && !albumMap.has(track.album.id)) {
                        albumMap.set(track.album.id, track.album);
                    }
                });
                finalAlbums = Array.from(albumMap.values());
            }

            // Enrich albums that have no artist or cover from track data
            if (finalAlbums.length > 0 && finalTracks.length > 0) {
                const trackInfoMap = new Map();
                finalTracks.forEach((track) => {
                    if (track.album && track.album.id && !trackInfoMap.has(track.album.id)) {
                        trackInfoMap.set(track.album.id, {
                            artist: track.artist || (track.artists && track.artists[0]) || null,
                            cover: (track.album && track.album.cover) || null,
                        });
                    }
                });
                finalAlbums.forEach((album) => {
                    const info = trackInfoMap.get(album.id);
                    if (!info) return;
                    if (!album.artist && !album.artists?.length && info.artist) {
                        album.artist = info.artist;
                        album.artists = [info.artist];
                    }
                    if (!album.cover && info.cover) {
                        album.cover = info.cover;
                    }
                });
            }""",
    "ui.js: enrich albums missing artist/cover from tracks",
)

# ── cache: per-type TTL ──
patch(
    "js/cache.js",
    "        this.ttl = options.ttl || 1000 * 60 * 30;",
    """        this.ttl = options.ttl || 1000 * 60 * 30;
        this.ttlByType = {
            search_all: 1000 * 60 * 10,
            search_tracks: 1000 * 60 * 10,
            search_artists: 1000 * 60 * 60,
            search_albums: 1000 * 60 * 30,
            search_playlists: 1000 * 60 * 60,
            search_videos: 1000 * 60 * 15,
        };""",
    "cache.js: per-type TTL map",
)

# ── cache: query normalization ──
patch(
    "js/cache.js",
    """    generateKey(type, params) {
        const paramString = typeof params === 'object' ? JSON.stringify(params) : String(params);
        return `${type}:${paramString}`;
    }""",
    """    generateKey(type, params) {
        let normalized = params;
        if (typeof params === 'string' && typeof type === 'string' && type.startsWith('search')) {
            normalized = params
                .trim()
                .toLowerCase()
                .normalize('NFD')
                .replace(/[\\u0300-\\u036f]/g, '');
        }
        const paramString = typeof normalized === 'object' ? JSON.stringify(normalized) : String(normalized);
        return `${type}:${paramString}`;
    }""",
    "cache.js: query normalization (trim/lowercase/NFD)",
)

# ── cache: per-type TTL lookup in get() ──
patch(
    "js/cache.js",
    """    async get(type, params) {
        const key = this.generateKey(type, params);

        if (this.memoryCache.has(key)) {
            const cached = this.memoryCache.get(key);
            if (Date.now() - cached.timestamp < this.ttl) {
                return cached.data;
            }
            this.memoryCache.delete(key);
        }

        if (this.db) {
            try {
                const cached = await this.getFromIndexedDB(key);
                if (cached && Date.now() - cached.timestamp < this.ttl) {""",
    """    async get(type, params) {
        const key = this.generateKey(type, params);
        const effectiveTtl = (this.ttlByType && this.ttlByType[type]) || this.ttl;

        if (this.memoryCache.has(key)) {
            const cached = this.memoryCache.get(key);
            if (Date.now() - cached.timestamp < effectiveTtl) {
                return cached.data;
            }
            this.memoryCache.delete(key);
        }

        if (this.db) {
            try {
                const cached = await this.getFromIndexedDB(key);
                if (cached && Date.now() - cached.timestamp < effectiveTtl) {""",
    "cache.js: per-type TTL lookup in get()",
)

# ── api.js: search limit=100 ──
patch("js/api.js",
    "const response = await this.fetchWithRetry(`/search/?q=${encodeURIComponent(query)}`, options);",
    "const response = await this.fetchWithRetry(`/search/?q=${encodeURIComponent(query)}&limit=${(options && options.limit) || 100}`, options);",
    "api.js: search() unified — limit=100")
patch("js/api.js",
    "const response = await this.fetchWithRetry(`/search/?s=${encodeURIComponent(query)}`, options);",
    "const response = await this.fetchWithRetry(`/search/?s=${encodeURIComponent(query)}&limit=${(options && options.limit) || 100}`, options);",
    "api.js: searchTracks — limit=100")
patch("js/api.js",
    "const response = await this.fetchWithRetry(`/search/?al=${encodeURIComponent(query)}`, options);",
    "const response = await this.fetchWithRetry(`/search/?al=${encodeURIComponent(query)}&limit=${(options && options.limit) || 100}`, options);",
    "api.js: searchAlbums — limit=100")
patch("js/api.js",
    "const response = await this.fetchWithRetry(`/search/?p=${encodeURIComponent(query)}`, options);",
    "const response = await this.fetchWithRetry(`/search/?p=${encodeURIComponent(query)}&limit=${(options && options.limit) || 100}`, options);",
    "api.js: searchPlaylists — limit=100")
patch("js/api.js",
    """const response = await this.fetchWithRetry(`/search/?v=${encodeURIComponent(query)}`, {
                ...options,
            });""",
    """const response = await this.fetchWithRetry(`/search/?v=${encodeURIComponent(query)}&limit=${(options && options.limit) || 100}`, {
                ...options,
            });""",
    "api.js: searchVideos — limit=100")

try:
    with open(os.path.join(PROJECT_DIR, "js/api.js"), "r", encoding="utf-8") as f:
        api_src = f.read()
    new_src, n = re.subn(
        r"(`/search/\?a=\$\{encodeURIComponent\(query\)\})(`)",
        r"\1&limit=${(options && options.limit) || 100}\2",
        api_src,
    )
    if n > 0:
        with open(os.path.join(PROJECT_DIR, "js/api.js"), "w", encoding="utf-8") as f:
            f.write(new_src)
        print("  + api.js: searchArtists — limit=100")
    else:
        print("  ! api.js: searchArtists pattern not found, skipping")
except Exception as e:
    print("  ! api.js: searchArtists patch failed: " + str(e))

# ── HiFi.ts: add artists.profileArt to unified search include ──
patch(
    "js/HiFi.ts",
    "'albums,albums.coverArt,albums.artists,tracks,tracks.artists,tracks.albums,tracks.albums.coverArt,artists,playlists,videos'",
    "'albums,albums.coverArt,albums.artists,tracks,tracks.artists,tracks.albums,tracks.albums.coverArt,artists,artists.profileArt,playlists,videos'",
    "HiFi.ts: add artists.profileArt to unified search include (fixes Picsum artist covers)",
)

# ── HiFi.ts: tracks.albums.coverArt on artist page — UPSTREAM MERGED (2026-08-16) ──
# Upstream now ships 'albums,albums.coverArt,tracks,tracks.albums,tracks.albums.coverArt,biography,profileArt'.

# ── Workbox: CacheFirst → NetworkOnly for audio/video ──
patch(
    "vite.config.ts",
    "handler: 'CacheFirst',\n                            options: {\n                                cacheName: 'media',",
    "handler: 'NetworkOnly',\n                            options: {\n                                cacheName: 'media',",
    "vite.config.ts: workbox audio/video CacheFirst -> NetworkOnly",
)

print("  ✓ All web patches applied.")
PYEOF

echo "  ✓ Patches done."

# ── 5. Build ──
echo ""
echo "▶ Building web app..."
npx vite build 2>&1 | tail -3
echo "  ✓ Build complete."

# ── 6. Package for upload ──
echo ""
echo "▶ Packaging dist/ for upload..."
# `zip -r` UPDATES an existing archive (stale entries from older builds survive) — start clean.
rm -f dist-web.zip
(cd dist && zip -r ../dist-web.zip . -x "*.map") 2>&1 | tail -3
SIZE=$(du -h "$PROJECT_DIR/dist-web.zip" | awk '{print $1}')
echo "  ✓ dist-web.zip (${SIZE}) ready."

# ── 7. Deploy via rsync over SSH (if accessible) ──
echo ""
echo "▶ Attempting deploy to ${DEPLOY_HOST}:${DEPLOY_PATH}/..."
if rsync -az --no-perms --omit-dir-times \
    -e "ssh -o ConnectTimeout=10 -o BatchMode=yes" \
    dist/ "${DEPLOY_HOST}:~/${DEPLOY_PATH}/" 2>&1; then
    echo "  ✓ Deployed to ${DEPLOY_HOST}:~/${DEPLOY_PATH}/"
    # assets/ is 100% build output (hashed chunks + public/assets) → safe to prune
    # stale files from previous builds there. Root is left untouched (.htaccess, cgi-bin, …).
    rsync -az --delete --no-perms --omit-dir-times \
        -e "ssh -o ConnectTimeout=10 -o BatchMode=yes" \
        dist/assets/ "${DEPLOY_HOST}:~/${DEPLOY_PATH}/assets/" 2>&1 \
        && echo "  ✓ Pruned stale files in assets/"
    echo ""
    echo "══════════════════════════════════════════"
    echo "  Live at: https://${DEPLOY_PATH}/"
    echo "══════════════════════════════════════════"
else
    echo "  ! rsync failed — use cPanel File Manager instead:"
    echo ""
    echo "  1. Open cPanel → File Manager → music.fabiodalez.it/"
    echo "  2. Upload: $PROJECT_DIR/dist-web.zip"
    echo "  3. Extract in place"
    echo "  4. Delete dist-web.zip"
    echo ""
    echo "══════════════════════════════════════════"
    echo "  ZIP: $PROJECT_DIR/dist-web.zip (${SIZE})"
    echo "══════════════════════════════════════════"
fi

# cleanup() runs automatically via trap EXIT
