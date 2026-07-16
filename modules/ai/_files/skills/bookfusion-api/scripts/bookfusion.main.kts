#!/usr/bin/env kotlin
@file:Repository("https://repo1.maven.org/maven2")
@file:DependsOn("com.google.code.gson:gson:2.11.0")
@file:DependsOn("org.yaml:snakeyaml:2.3")

/*
 * bookfusion-api skill — CLI client for the (reverse-engineered) BookFusion mobile JSON API.
 *
 * Transport-faithful: talks to https://www.bookfusion.com exactly like the Android app
 * (X-Token auth, Accept: application/json; api_version=10), but identifies itself honestly
 * via the User-Agent so usage is attributable to this skill.
 *
 * UNOFFICIAL. Reverse-engineered from the app; unversioned server API; may break; use may
 * conflict with BookFusion's ToS. See references/ for details.
 *
 * HTTP = JDK java.net.http.HttpClient (no dependency). JSON = Gson (token extraction, pretty).
 */

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.RandomAccessFile
import java.math.BigDecimal
import java.math.BigInteger
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.time.Duration
import java.util.UUID
import kotlin.system.exitProcess

// ---------------------------------------------------------------------------- constants
val SKILL_NAME = "bookfusion-api"
val SKILL_VERSION = "1.0.0"
val DEFAULT_BASE = "https://www.bookfusion.com"
val DEFAULT_RATE = 5.0
val API_ACCEPT = "application/json; api_version=10"
val USER_AGENT = "$SKILL_NAME-skill/$SKILL_VERSION (Claude Code Skill; +https://www.bookfusion.com)"
val DEFAULT_MAX_BYTES = 32 * 1024

// exit codes
val EX_OK = 0
val EX_USAGE = 2
val EX_AUTH = 3
val EX_GATED = 4
val EX_HTTP = 5
val EX_IO = 6

enum class Tier { SAFE, WRITE, DANGEROUS }
data class Cmd(
    val id: String, val method: String, val path: String, val tier: Tier,
    val pathParams: List<String>, val queryParams: List<String>,
    val hasBody: Boolean, val multipart: Boolean,
    // Name of the multipart binary part. Real API: createHighlight expects "binary", every other
    // multipart command (updateUserBook, finalizeBookUpload, updateUserProfile) expects "file".
    val filePart: String = "file",
)

// commands whose purpose IS authentication / account creation — never auto-login for these
val AUTH_CMDS = setOf("authenticate", "signup", "authFacebook", "authGoogle", "authChallenge", "updateAuthToken")
// intentionally excluded (documented, never wrapped): createReaderSubscription (payment),
// disconnectFacebook (can strand account access). No account-delete endpoint exists in the API.
val EXCLUDED = mapOf(
    "createReaderSubscription" to "POST /api/user/reader_subscription (payment / subscription mutation)",
    "disconnectFacebook" to "POST /api/v1/profile/facebook/disconnect (can strand account access)",
)

// ---------------------------------------------------------------------------- registry (generated from the OpenAPI spec)
val REGISTRY = listOf(
    Cmd("deleteBookBookmark", "POST", "/api/v2/library/books/{number}/bookmarks/{id}/delete", Tier.DANGEROUS, listOf("number", "id"), listOf(), false, false),
    Cmd("deleteBookshelf", "DELETE", "/api/user/bookshelves/{id}", Tier.DANGEROUS, listOf("id"), listOf(), false, false),
    Cmd("deleteHighlight", "DELETE", "/api/user/highlights/{id}", Tier.DANGEROUS, listOf("id"), listOf(), false, false),
    Cmd("deleteReaderPreset", "DELETE", "/api/user/reader_presets/{id}", Tier.DANGEROUS, listOf("id"), listOf(), false, false),
    Cmd("deleteSeries", "DELETE", "/api/user/series/{id}", Tier.DANGEROUS, listOf("id"), listOf(), false, false),
    Cmd("deleteUserBook", "DELETE", "/api/user/books/{id}", Tier.DANGEROUS, listOf("id"), listOf(), false, false),
    Cmd("updateUserBook", "PATCH", "/api/user/books/{id}", Tier.DANGEROUS, listOf("id"), listOf(), true, true),
    Cmd("authChallenge", "GET", "/api/v3/auth/challenge", Tier.SAFE, listOf(), listOf("email"), false, false),
    Cmd("checkBorrowBook", "GET", "/api/user/libraries/books/{book_id}/borrow", Tier.SAFE, listOf("book_id"), listOf(), false, false),
    Cmd("getBookReadingPosition", "GET", "/api/user/books/{number}/reading_position", Tier.SAFE, listOf("number"), listOf(), false, false),
    Cmd("getLibraryMemberships", "GET", "/api/user/libraries/membership", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("getReaderSubscription", "GET", "/api/user/reader_subscription", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("getReaderSubscriptionPricing", "GET", "/api/user/reader_subscription/pricing", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("getRelatedLibraryBooks", "GET", "/api/user/libraries/books/{book_id}/related_books", Tier.SAFE, listOf("book_id"), listOf(), false, false),
    Cmd("getTtsCredentials", "POST", "/api/user/tts", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("getUser", "GET", "/api/v1/user", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("listBookBookmarks", "GET", "/api/v2/library/books/{number}/bookmarks", Tier.SAFE, listOf("number"), listOf(), false, false),
    Cmd("listHighlightColors", "GET", "/api/user/highlights/colors", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("listHighlightExportFormats", "GET", "/api/user/highlights/export/formats", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("listHighlightTags", "GET", "/api/user/highlights/tags", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("searchAuthors", "POST", "/api/user/authors/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchBookshelves", "POST", "/api/user/bookshelves/search", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("searchCategories", "POST", "/api/user/categories/search", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("searchHighlightAuthors", "POST", "/api/user/highlights/authors/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchHighlightCategories", "POST", "/api/user/highlights/categories/search", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("searchHighlightTags", "POST", "/api/user/highlights/tags/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchHighlights", "POST", "/api/user/highlights/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchLibraries", "POST", "/api/user/libraries/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchLibraryAuthors", "POST", "/api/user/libraries/{slug}/authors/search", Tier.SAFE, listOf("slug"), listOf(), true, false),
    Cmd("searchLibraryBookListBooks", "POST", "/api/user/libraries/book_lists/{categoryId}/books/search", Tier.SAFE, listOf("categoryId"), listOf(), true, false),
    Cmd("searchLibraryBookLists", "POST", "/api/user/libraries/{slug}/book_lists/search", Tier.SAFE, listOf("slug"), listOf(), true, false),
    Cmd("searchLibraryBooks", "POST", "/api/user/libraries/{slug}/books/search", Tier.SAFE, listOf("slug"), listOf(), true, false),
    Cmd("searchLibraryCategories", "POST", "/api/user/libraries/{slug}/categories/search", Tier.SAFE, listOf("slug"), listOf(), false, false),
    Cmd("searchLibraryTags", "POST", "/api/user/libraries/{slug}/tags/search", Tier.SAFE, listOf("slug"), listOf(), true, false),
    Cmd("searchReaderPresets", "POST", "/api/user/reader_presets/search", Tier.SAFE, listOf(), listOf(), false, false),
    Cmd("searchSeries", "POST", "/api/user/series/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchSeriesBooks", "POST", "/api/user/series/{id}/books/search", Tier.SAFE, listOf("id"), listOf(), true, false),
    Cmd("searchTags", "POST", "/api/user/tags/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("searchUserBooks", "POST", "/api/user/books/search", Tier.SAFE, listOf(), listOf(), true, false),
    Cmd("addBookBookmark", "POST", "/api/v2/library/books/{number}/bookmarks", Tier.WRITE, listOf("number"), listOf(), true, false),
    Cmd("authFacebook", "POST", "/api/v3/auth/facebook", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("authGoogle", "POST", "/api/user/auth/google", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("authenticate", "POST", "/api/v3/auth.json", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("borrowBook", "POST", "/api/user/libraries/books/{book_id}/borrow", Tier.WRITE, listOf("book_id"), listOf(), false, false),
    Cmd("createBookshelf", "POST", "/api/user/bookshelves", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("createHighlight", "POST", "/api/user/highlights", Tier.WRITE, listOf(), listOf(), true, true, "binary"),
    Cmd("createReaderPreset", "POST", "/api/user/reader_presets", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("createSeries", "POST", "/api/user/series", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("exportHighlights", "POST", "/api/user/highlights/export", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("finalizeBookUpload", "POST", "/api/user/uploads/finalize", Tier.WRITE, listOf(), listOf(), true, true),
    Cmd("initBookUpload", "POST", "/api/user/uploads/init", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("joinLibrary", "POST", "/api/v3/libraries/{slug}/join", Tier.WRITE, listOf("slug"), listOf(), false, false),
    Cmd("leaveLibrary", "POST", "/api/v3/libraries/{slug}/leave", Tier.WRITE, listOf("slug"), listOf(), false, false),
    Cmd("sendBookToKindle", "POST", "/api/v1/library/books/{number}/kindle", Tier.WRITE, listOf("number"), listOf(), false, false),
    Cmd("signup", "POST", "/api/v3/signup", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("trackBookReadingTime", "POST", "/api/v1/library/books/{number}/track_time", Tier.WRITE, listOf("number"), listOf(), true, false),
    Cmd("updateAuthToken", "POST", "/api/v3/auth/token", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("updateBookReadingPosition", "POST", "/api/user/books/{number}/reading_position", Tier.WRITE, listOf("number"), listOf(), true, false),
    Cmd("updateBookshelf", "PATCH", "/api/user/bookshelves/{id}", Tier.WRITE, listOf("id"), listOf(), true, false),
    Cmd("updateHighlight", "PATCH", "/api/user/highlights/{id}", Tier.WRITE, listOf("id"), listOf(), true, false),
    Cmd("updateProfileSettings", "POST", "/api/v1/profile/settings", Tier.WRITE, listOf(), listOf(), true, false),
    Cmd("updateReaderPreset", "PATCH", "/api/user/reader_presets/{id}", Tier.WRITE, listOf("id"), listOf(), true, false),
    Cmd("updateSeries", "PATCH", "/api/user/series/{id}", Tier.WRITE, listOf("id"), listOf(), true, false),
    Cmd("updateUserProfile", "PATCH", "/api/user/profile", Tier.WRITE, listOf(), listOf(), true, true),
).associateBy { it.id }

val GSON: Gson = GsonBuilder().disableHtmlEscaping().create()
val PRETTY: Gson = GsonBuilder().disableHtmlEscaping().setPrettyPrinting().create()

// ---------------------------------------------------------------------------- helpers
fun err(msg: String) = System.err.println(msg)
fun die(code: Int, msg: String): Nothing { err(msg); exitProcess(code) }

fun stateDir(): Path {
    val base = System.getenv("XDG_STATE_HOME")?.takeIf { it.isNotBlank() }
        ?: (System.getProperty("user.home") + "/.local/state")
    val p = Paths.get(base, "$SKILL_NAME-skill")
    Files.createDirectories(p)
    return p
}

fun sha256(s: String): String =
    MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

fun writePrivate(path: Path, content: String) {
    Files.write(path, content.toByteArray())
    try { Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------")) } catch (_: Exception) {}
}

fun enc(s: String): String = URLEncoder.encode(s, StandardCharsets.UTF_8)

/** Expand only a LEADING ~ / ~/ to $HOME (a mid-path ~, e.g. ./backup~1/x, must be left intact). */
fun expandTilde(p: String): String {
    val home = System.getProperty("user.home")
    return when {
        p == "~" -> home
        p.startsWith("~/") -> home + p.substring(1)
        else -> p
    }
}

/** Persistent, per-install pseudo device id (mirrors the app's X-Device). */
fun deviceId(): String {
    val f = stateDir().resolve("device-id")
    if (Files.exists(f)) return Files.readString(f).trim()
    val id = UUID.randomUUID().toString()
    writePrivate(f, id)
    return id
}

// ------------- credential resolution (first non-empty wins; value never printed) -------------
data class Resolved(val value: String, val source: String)

fun readFileTrim(p: String): String? = try {
    val path = Paths.get(expandTilde(p))
    if (Files.exists(path)) Files.readString(path).trim().ifBlank { null } else null
} catch (_: Exception) { null }

fun resolveCredential(kind: String, opts: Map<String, String>): Resolved? {
    // kind = "username" | "password"
    val cliFile = opts["--$kind-file"]
    if (cliFile != null) readFileTrim(cliFile)?.let { return Resolved(it, "--$kind-file") }
    val envVar = "BOOKFUSION_${kind.uppercase()}"
    System.getenv(envVar)?.takeIf { it.isNotBlank() }?.let { return Resolved(it, "\$$envVar") }
    System.getenv("${envVar}_FILE")?.let { readFileTrim(it)?.let { v -> return Resolved(v, "\$${envVar}_FILE") } }
    readFileTrim("~/.config/sops-nix/secrets/bookfusion_$kind")?.let { return Resolved(it, "sops-nix:bookfusion_$kind") }
    opts["--$kind"]?.let {
        err("warning: --$kind passed inline may leak via shell history; prefer a file/env/sops source")
        return Resolved(it, "--$kind (inline)")
    }
    return null
}

// ---------------------------------------------------------------------------- rate limiter (cross-process, file-locked)
fun rateGate(minIntervalMs: Long) {
    if (minIntervalMs <= 0) return
    val f = stateDir().resolve("last-request").toFile()
    RandomAccessFile(f, "rw").use { raf ->
        raf.channel.lock().use {   // held during sleep → serializes concurrent invocations
            val last = try { raf.seek(0); raf.readLine()?.trim()?.toLongOrNull() ?: 0L } catch (_: Exception) { 0L }
            // Clamp to one interval: a stale/clock-skewed FUTURE timestamp must never make us sleep
            // (unboundedly) while holding the cross-process file lock.
            val wait = (last + minIntervalMs - System.currentTimeMillis()).coerceAtMost(minIntervalMs)
            if (wait > 0) Thread.sleep(wait)
            val now = System.currentTimeMillis()
            raf.setLength(0); raf.seek(0); raf.writeBytes(now.toString())
        }
    }
}

// ---------------------------------------------------------------------------- HTTP
val CLIENT: HttpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(20)).build()

data class Ctx(val baseUrl: String, val minIntervalMs: Long, val token: String, val device: String)

// Response bodies are read as raw bytes so binary payloads (exported PDFs, cover images, TTS audio)
// survive byte-exact; text responses are decoded on demand via bodyText().
fun send(ctx: Ctx, method: String, url: String, body: ByteArray?, contentType: String?): HttpResponse<ByteArray> {
    rateGate(ctx.minIntervalMs)
    val b = HttpRequest.newBuilder(URI.create(url))
        .timeout(Duration.ofSeconds(60))
        .header("Accept", API_ACCEPT)
        .header("User-Agent", USER_AGENT)
        .header("X-Client", SKILL_NAME)
        .header("X-Capabilities", "direct-upload")
        .header("X-Device", ctx.device)
        .header("X-Token", ctx.token)
    if (contentType != null) b.header("Content-Type", contentType)
    val pub = if (body != null) HttpRequest.BodyPublishers.ofByteArray(body) else HttpRequest.BodyPublishers.noBody()
    b.method(method, pub)
    return try { CLIENT.send(b.build(), HttpResponse.BodyHandlers.ofByteArray()) }
    catch (e: Exception) { die(EX_IO, "network error: ${e.message}") }
}

fun bodyText(resp: HttpResponse<ByteArray>): String = String(resp.body(), StandardCharsets.UTF_8)
/** A response is text (JSON/TSV path) when its Content-Type is textual; a missing CT is treated as text (legacy behavior). */
fun isTextResponse(ct: String?): Boolean {
    val c = ct?.lowercase() ?: return true
    return c.contains("json") || c.startsWith("text/") || c.contains("xml") ||
        c.contains("javascript") || c.contains("x-www-form-urlencoded")
}
fun extForContentType(ct: String?): String = when {
    ct == null -> "bin"
    ct.contains("pdf") -> "pdf"; ct.contains("epub") -> "epub"; ct.contains("zip") -> "zip"
    ct.contains("png") -> "png"; ct.contains("jpeg") || ct.contains("jpg") -> "jpg"
    else -> "bin"
}

// ---------------------------------------------------------------------------- token cache + login
fun tokenCachePath(base: String, user: String?): Path =
    stateDir().resolve("token-${sha256(base + "|" + (user ?: ""))}.json")

// token resolution (never printed): env -> --token-file -> $BOOKFUSION_TOKEN_FILE -> on-disk cache
fun cachedToken(base: String, user: String?, opts: Map<String, String>): String? {
    System.getenv("BOOKFUSION_TOKEN")?.takeIf { it.isNotBlank() }?.let { return it }
    opts["--token-file"]?.let { readFileTrim(it)?.let { v -> return v } }
    System.getenv("BOOKFUSION_TOKEN_FILE")?.let { readFileTrim(it)?.let { v -> return v } }
    val p = tokenCachePath(base, user)
    if (!Files.exists(p)) return null
    return try { JsonParser.parseString(Files.readString(p)).asJsonObject.get("token")?.asString?.ifBlank { null } }
    catch (_: Exception) { null }
}

fun doLogin(base: String, minInterval: Long, device: String, opts: Map<String, String>): String {
    val user = resolveCredential("username", opts)
        ?: die(EX_AUTH, "no username: set BOOKFUSION_USERNAME, --username-file, or ~/.config/sops-nix/secrets/bookfusion_username")
    val pass = resolveCredential("password", opts)
        ?: die(EX_AUTH, "no password: set BOOKFUSION_PASSWORD, --password-file, or ~/.config/sops-nix/secrets/bookfusion_password")
    err("login: user from ${user.source}, password from ${pass.source} -> POST $base/api/v3/auth.json")
    val payload = JsonObject().apply { addProperty("email", user.value); addProperty("password", pass.value) }
    val ctx = Ctx(base, minInterval, "", device)
    val resp = send(ctx, "POST", "$base/api/v3/auth.json", GSON.toJson(payload).toByteArray(), "application/json")
    val obj = try { JsonParser.parseString(bodyText(resp)).asJsonObject } catch (_: Exception) { JsonObject() }
    val token = obj.get("token")?.takeIf { !it.isJsonNull }?.asString
    if (resp.statusCode() !in 200..299 || token.isNullOrBlank()) {
        val e = obj.get("error")?.takeIf { !it.isJsonNull }?.asString ?: "unknown error"
        die(EX_AUTH, "login failed (HTTP ${resp.statusCode()}): $e")
    }
    val cache = JsonObject().apply {
        addProperty("token", token); addProperty("user", user.value); addProperty("savedAt", System.currentTimeMillis())
    }
    writePrivate(tokenCachePath(base, user.value), GSON.toJson(cache))
    // also cache under the null-user key so token-only lookups hit
    writePrivate(tokenCachePath(base, null), GSON.toJson(cache))
    return token
}

fun ensureToken(base: String, minInterval: Long, device: String, opts: Map<String, String>): String {
    val user = resolveCredential("username", opts)?.value
    cachedToken(base, user, opts)?.let { return it }
    return doLogin(base, minInterval, device, opts)
}

// ---------------------------------------------------------------------------- output
// Context economy: only small, non-credential responses print inline. Large or credential-bearing
// responses go to a temp file (real values), and context gets just the path + a redacted preview.
// Lists render as TSV by default (compact) or JSON Lines; single objects as JSON.
val SENSITIVE_KEYS = setOf(
    "token", "access_token", "refresh_token", "id_token", "facebook_token", "google_token",
    "api_token", "api_key", "apikey", "password", "client_secret", "secret", "authenticity_token",
)
fun isSensitiveKey(k: String): Boolean {
    val l = k.lowercase()
    // exact set, any *password*, and any *_token (catches preview_token from getTtsCredentials)
    return l in SENSITIVE_KEYS || l.contains("password") || l.endsWith("_token")
}
/** A URL-bearing key. Redacted ONLY when it sits in the same object as a real credential (see redactTree),
 *  so a signed TTS streaming `url` is masked while ordinary book `read_url`/cover `url` are left intact. */
fun isUrlKey(k: String): Boolean { val l = k.lowercase(); return l == "url" || l.endsWith("_url") }

fun parseOrNull(s: String): JsonElement? = try { JsonParser.parseString(s) } catch (_: Exception) { null }

fun treeHasSensitive(e: JsonElement?): Boolean = when {
    e == null -> false
    e.isJsonObject -> e.asJsonObject.entrySet().any { isSensitiveKey(it.key) || treeHasSensitive(it.value) }
    e.isJsonArray -> e.asJsonArray.any { treeHasSensitive(it) }
    else -> false
}
fun redactTree(e: JsonElement): JsonElement = when {
    e.isJsonObject -> JsonObject().also { o ->
        val hasSecretSibling = e.asJsonObject.entrySet().any { isSensitiveKey(it.key) }
        e.asJsonObject.entrySet().forEach { (k, v) ->
            val mask = isSensitiveKey(k) || (isUrlKey(k) && hasSecretSibling)
            o.add(k, if (mask) JsonPrimitive("***REDACTED***") else redactTree(v))
        }
    }
    e.isJsonArray -> JsonArray().also { a -> e.asJsonArray.forEach { a.add(redactTree(it)) } }
    else -> e
}

fun cell(v: JsonElement): String = (when {
    v.isJsonNull -> ""
    v.isJsonPrimitive -> v.asString
    else -> GSON.toJson(v)
}).replace("\t", " ").replace("\r", " ").replace("\n", "\\n")

fun toTsv(arr: JsonArray): String {
    if (arr.size() == 0) return ""
    if (!arr.all { it.isJsonObject }) return arr.joinToString("\n") { if (it.isJsonPrimitive || it.isJsonNull) cell(it) else GSON.toJson(it) }
    val headers = LinkedHashSet<String>()
    arr.forEach { it.asJsonObject.keySet().forEach { k -> headers.add(k) } }
    val sb = StringBuilder(headers.joinToString("\t")).append("\n")
    arr.forEach { el -> val o = el.asJsonObject; sb.append(headers.joinToString("\t") { h -> if (o.has(h)) cell(o.get(h)) else "" }).append("\n") }
    return sb.toString().trimEnd('\n')
}

fun formatTree(e: JsonElement, fmt: String, pretty: Boolean): String {
    val f = if (fmt != "auto") fmt
    else if (e.isJsonArray) { if (e.asJsonArray.size() == 0 || e.asJsonArray.get(0).isJsonObject) "tsv" else "jsonl" }
    else "json"
    return when (f) {
        "tsv" -> if (e.isJsonArray) toTsv(e.asJsonArray) else if (pretty) PRETTY.toJson(e) else GSON.toJson(e)
        "jsonl" -> if (e.isJsonArray) e.asJsonArray.joinToString("\n") { GSON.toJson(it) } else GSON.toJson(e)
        else -> if (pretty) PRETTY.toJson(e) else GSON.toJson(e)
    }
}

data class OutOpts(val fmt: String, val pretty: Boolean, val inlineMax: Int, val previewLines: Int, val forceStdout: Boolean, val outPath: String?)

fun emit(body: String, o: OutOpts) {
    if (body.isBlank()) return                          // e.g. HTTP 204, empty body
    val parsed = parseOrNull(body)
    if (parsed == null) { writeOrInline(body, body, false, null, "txt", o); return }  // non-JSON: passthrough
    val hasSecret = treeHasSensitive(parsed)
    val full = formatTree(parsed, o.fmt, o.pretty)
    val redacted = if (hasSecret) formatTree(redactTree(parsed), o.fmt, o.pretty) else full
    val records = if (parsed.isJsonArray) parsed.asJsonArray.size() else null
    val ext = if (o.fmt == "tsv" || (o.fmt == "auto" && parsed.isJsonArray && (parsed.asJsonArray.size() == 0 || parsed.asJsonArray.get(0).isJsonObject))) "tsv" else "json"
    writeOrInline(full, redacted, hasSecret, records, ext, o)
}

fun writeOrInline(full: String, redacted: String, hasSecret: Boolean, records: Int?, ext: String, o: OutOpts) {
    val bytes = full.toByteArray()
    // credential-bearing OR too big OR explicit --out => write to file (never dump secrets to context)
    val mustFile = hasSecret || o.outPath != null || (!o.forceStdout && bytes.size > o.inlineMax)
    if (!mustFile) { println(redacted); return }        // redacted == full when no secrets present
    val path = if (o.outPath != null) Paths.get(o.outPath) else Files.createTempFile("$SKILL_NAME-", ".$ext")
    Files.write(path, bytes)
    if (hasSecret) try { Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-------")) } catch (_: Exception) {}
    val rec = if (records != null) "records=$records " else ""
    val sec = if (hasSecret) "contains-credentials=yes " else ""
    err("output: $rec${sec}bytes=${bytes.size} format=$ext file=$path")
    if (o.previewLines > 0) {
        err("--- preview (redacted, first ${o.previewLines} lines; full data in the file above) ---")
        redacted.lineSequence().take(o.previewLines).forEach { err(it) }
    }
    println(path.toString())                             // stdout = the file path (machine-usable)
}

/** Write a binary response body byte-exact to a file (never inline: it would corrupt the terminal/context). */
fun emitBytes(bytes: ByteArray, ct: String?, o: OutOpts) {
    val path = if (o.outPath != null) Paths.get(o.outPath) else Files.createTempFile("$SKILL_NAME-", ".${extForContentType(ct)}")
    Files.write(path, bytes)
    err("output: binary content-type=$ct bytes=${bytes.size} file=$path")
    println(path.toString())                             // stdout = the file path (byte-exact file)
}

// ---------------------------------------------------------------------------- multipart
fun multipartBody(payloadJson: String, filePath: String?, partName: String): Pair<ByteArray, String> {
    val boundary = "----bookfusion" + UUID.randomUUID().toString().replace("-", "")
    val out = java.io.ByteArrayOutputStream()
    fun w(s: String) = out.write(s.toByteArray(StandardCharsets.UTF_8))
    w("--$boundary\r\n")
    w("Content-Disposition: form-data; name=\"payload\"\r\n")
    w("Content-Type: application/json\r\n\r\n")
    w(payloadJson); w("\r\n")
    if (filePath != null) {
        val f = Paths.get(expandTilde(filePath))
        if (!Files.exists(f)) die(EX_USAGE, "--file not found: $filePath")
        val name = f.fileName.toString()
        w("--$boundary\r\n")
        // Part name differs per endpoint (see Cmd.filePart): "binary" for createHighlight, "file" otherwise.
        w("Content-Disposition: form-data; name=\"$partName\"; filename=\"$name\"\r\n")
        w("Content-Type: application/octet-stream\r\n\r\n")
        out.write(Files.readAllBytes(f)); w("\r\n")
    }
    w("--$boundary--\r\n")
    return out.toByteArray() to "multipart/form-data; boundary=$boundary"
}

// ---------------------------------------------------------------------------- arg parsing
val BOOL_FLAGS = setOf(
    "--dangerous", "--pretty", "--data-stdin", "--stdout", "--help", "-h", "--dry-run", "--force", "--no-validate",
    "--quiet", "--continue-on-error", "--stop-on-error",
)
fun parse(argv: List<String>): Triple<String?, MutableMap<String, String>, MutableSet<String>> {
    var command: String? = null
    val opts = mutableMapOf<String, String>()
    val flags = mutableSetOf<String>()
    var i = 0
    while (i < argv.size) {
        val a = argv[i]
        when {
            a in BOOL_FLAGS -> flags.add(a)
            a.startsWith("--") -> {
                val v = if (i + 1 < argv.size) argv[++i] else die(EX_USAGE, "missing value for $a")
                opts[a] = v
            }
            command == null -> command = a
            else -> die(EX_USAGE, "unexpected argument: $a")
        }
        i++
    }
    return Triple(command, opts, flags)
}

fun readBody(cmd: Cmd, opts: Map<String, String>, flags: Set<String>): String? {
    if (!cmd.hasBody && !cmd.multipart) return null
    val raw = when {
        "--data-stdin" in flags -> System.`in`.readBytes().toString(StandardCharsets.UTF_8)
        opts["--data-file"] != null -> readFileTrim(opts["--data-file"]!!) ?: die(EX_USAGE, "--data-file empty/not found")
        opts["--data"] != null -> opts["--data"]!!
        else -> null
    }
    if (raw == null) return if (cmd.hasBody || cmd.multipart) "{}" else null
    try { JsonParser.parseString(raw) } catch (e: Exception) { die(EX_USAGE, "--data is not valid JSON: ${e.message}") }
    return raw
}

// ---------------------------------------------------------------------------- usage
fun usage(): String = """
$SKILL_NAME — CLI for the (reverse-engineered, unofficial) BookFusion mobile API.

USAGE:
  bookfusion <command> [--param value ...] [--data '<json>' | --data-file P | --data-stdin] [flags]
  bookfusion batch [--dangerous] [--continue-on-error|--stop-on-error]   # JSONL ops on stdin, one login
  bookfusion login | logout | whoami | list | help

FLAGS:
  --dangerous            required to run a DANGEROUS (destructive) command
  --dry-run              validate the request offline and print it; do NOT send (no network/login)
  --force                send even if validation found hard errors (still coerces + reports)
  --no-validate          skip OpenAPI request validation/coercion entirely
  --spec PATH            OpenAPI spec used for validation (env BOOKFUSION_OPENAPI; set by the wrapper)
  --data '<json>'        request body (also --data-file PATH, --data-stdin)
  --file PATH            binary part for multipart commands (upload/cover/highlight image)
  --format F             output format: auto (default) | tsv | jsonl | json (env BOOKFUSION_FORMAT)
  --pretty               pretty-print JSON output
  --quiet                for WRITE/DANGEROUS commands, suppress the 2xx response body (print only 'ok:' on stderr)
  --stdout               force full output inline (only for small, non-credential responses)
  --out PATH             write the full response to PATH instead of a temp file
  --continue-on-error    (batch) keep going after a failing op — the default; exit non-zero if any failed
  --stop-on-error        (batch) stop at the first failing op
  --preview-lines N      lines of redacted preview to show for filed output (default 10; 0 = none)
  --max-bytes N          inline size limit; larger responses go to a temp file (env BOOKFUSION_OUTPUT_MAX_BYTES)
  --base-url URL         override API base (env BOOKFUSION_BASE_URL; default $DEFAULT_BASE)
  --rate N               max requests/sec (env BOOKFUSION_RATE_LIMIT; default $DEFAULT_RATE)
  --<pathparam> V        e.g. --id 123 --number 456 --slug foo --book_id 789 --email a@b.c

OUTPUT (context economy): lists render as compact TSV by default; large responses and any response
containing credentials are written to a temp file (0600 for credentials) — stdout then carries only the
file path plus a short redacted preview on stderr. Sensitive keys (token/password/…) are never printed.

VALIDATION: request bodies (and path/query params) are checked against the shipped OpenAPI spec before
sending. Safe datatype/shape mistakes are auto-fixed and reported as 'fix:' lines (e.g. "20"→20,
scalar→[scalar], enum case). Missing required fields and uncoercible types are 'error:' lines and, by
default, block the request (exit 2) BEFORE any round trip. Unknown fields / unknown enum values are
'warn:' lines and still send (the spec is reverse-engineered and may be incomplete). Use --dry-run to
validate only, --force to send despite errors, --no-validate to skip. Fixes never print secret values.

CREDENTIALS (first non-empty wins; values never printed):
  username: --username-file > ${'$'}BOOKFUSION_USERNAME > ${'$'}BOOKFUSION_USERNAME_FILE >
            ~/.config/sops-nix/secrets/bookfusion_username > --username (inline, warned)
  password: same order with bookfusion_password
  token:    ${'$'}BOOKFUSION_TOKEN > --token-file > ${'$'}BOOKFUSION_TOKEN_FILE > on-disk cache (auto-login otherwise)

Run `bookfusion list` for all commands and their danger tier.
""".trimIndent()

fun listCommands(): String {
    val sb = StringBuilder()
    for (tier in listOf(Tier.SAFE, Tier.WRITE, Tier.DANGEROUS)) {
        sb.append("\n== $tier ==\n")
        REGISTRY.values.filter { it.tier == tier }.sortedBy { it.id }.forEach {
            val flag = if (it.tier == Tier.DANGEROUS) "  [needs --dangerous]" else ""
            val mp = if (it.multipart) "  (multipart: --data payload + --file)" else ""
            sb.append("  %-30s %-6s %s%s%s\n".format(it.id, it.method, it.path, flag, mp))
        }
    }
    sb.append("\n== EXCLUDED (intentionally not available) ==\n")
    EXCLUDED.forEach { (id, why) -> sb.append("  %-30s %s\n".format(id, why)) }
    return sb.toString()
}

// ---------------------------------------------------------------------------- request validation
// Validate the outgoing request against the shipped OpenAPI spec BEFORE sending, so the agent gets
// local, field-level feedback in one shot instead of a wasted HTTP round trip. Safe datatype/shape
// mistakes are auto-fixed (coerced); mistakes we cannot safely fix (missing required fields,
// uncoercible types) are hard errors. The spec is reverse-engineered/unversioned, so unknown fields
// and unknown enum values are WARNINGS (still sent), and --force / --no-validate always override.
@Suppress("UNCHECKED_CAST")
fun asMap(o: Any?): Map<String, Any?>? = o as? Map<String, Any?>
@Suppress("UNCHECKED_CAST")
fun asList(o: Any?): List<Any?>? = o as? List<Any?>

private var SPEC_LOADED = false
private var SPEC_CACHE: Map<String, Any?>? = null
fun loadSpec(specOpt: String?): Map<String, Any?>? {
    if (SPEC_LOADED) return SPEC_CACHE
    SPEC_LOADED = true
    val p = (specOpt ?: System.getenv("BOOKFUSION_OPENAPI"))?.takeIf { it.isNotBlank() } ?: return null
    val path = Paths.get(expandTilde(p))
    if (!Files.exists(path)) return null
    SPEC_CACHE = try {
        asMap(Yaml(SafeConstructor(LoaderOptions())).load<Any?>(Files.readString(path)))
    } catch (_: Exception) { null }
    return SPEC_CACHE
}

/** Resolve a (possibly chained) `$ref` node into the schema it points at; returns the node unchanged if not a ref. */
fun resolveRef(spec: Map<String, Any?>, node: Any?): Any? {
    var cur = node
    var guard = 0
    while (guard++ < 32) {
        val ref = asMap(cur)?.get("\$ref") as? String ?: return cur
        var t: Any? = spec
        for (part in ref.removePrefix("#/").split("/")) t = asMap(t)?.get(part) ?: return null
        cur = t
    }
    return cur
}

fun operationNode(spec: Map<String, Any?>, cmd: Cmd): Map<String, Any?>? =
    asMap(asMap(asMap(spec["paths"])?.get(cmd.path))?.get(cmd.method.lowercase()))

/** The raw request-body schema node ($ref or inline) for an operation: the JSON body, or the multipart `payload` part. */
fun requestSchema(spec: Map<String, Any?>, op: Map<String, Any?>, multipart: Boolean): Any? {
    val content = asMap(asMap(op["requestBody"])?.get("content")) ?: return null
    return if (multipart) {
        val sch = asMap(resolveRef(spec, asMap(content["multipart/form-data"])?.get("schema"))) ?: return null
        asMap(sch["properties"])?.get("payload")
    } else asMap(content["application/json"])?.get("schema")
}

class VCtx {
    val fixes = mutableListOf<String>()
    val warns = mutableListOf<String>()
    val errors = mutableListOf<String>()
}

fun jpath(base: String, key: String): String = if (base.isEmpty()) key else "$base.$key"
fun jtype(e: JsonElement): String = when {
    e.isJsonNull -> "null"; e.isJsonArray -> "array"; e.isJsonObject -> "object"
    e.isJsonPrimitive -> e.asJsonPrimitive.let { if (it.isBoolean) "boolean" else if (it.isNumber) "number" else "string" }
    else -> "unknown"
}
/** Redact a value in a diagnostic message when the field it belongs to is sensitive (token/password/…). */
fun redactVal(path: String, v: String): String {
    val leaf = path.substringAfterLast('.').substringBefore('[')
    return if (isSensitiveKey(leaf)) "***REDACTED***" else v
}

fun levenshtein(a: String, b: String): Int {
    val dp = IntArray(b.length + 1) { it }
    for (i in 1..a.length) {
        var prev = dp[0]; dp[0] = i
        for (j in 1..b.length) {
            val tmp = dp[j]
            dp[j] = if (a[i - 1] == b[j - 1]) prev else 1 + minOf(prev, dp[j], dp[j - 1])
            prev = tmp
        }
    }
    return dp[b.length]
}
/** Closest candidate within a small edit distance, for did-you-mean hints (never used to auto-rewrite). */
fun closest(s: String, candidates: Collection<String>): String? {
    var best: String? = null; var bestD = Int.MAX_VALUE
    for (c in candidates) { val d = levenshtein(s.lowercase(), c.lowercase()); if (d in 1 until bestD) { bestD = d; best = c } }
    val threshold = minOf(2, Math.ceil(s.length / 3.0).toInt())
    return if (best != null && bestD <= threshold) best else null
}

fun typeHint(spec: Map<String, Any?>, schemaRaw: Any?): String {
    val s = asMap(resolveRef(spec, schemaRaw)) ?: return ""
    asList(s["enum"])?.let { return " (one of [${it.joinToString(", ")}])" }
    val t = s["type"] as? String ?: return ""
    if (t == "array") {
        val items = asMap(resolveRef(spec, s["items"]))
        asList(items?.get("enum"))?.let { return " (array of [${it.joinToString(", ")}])" }
        return (items?.get("type") as? String)?.let { " (array of $it)" } ?: " (array)"
    }
    return " ($t)"
}

fun coerceEnum(value: JsonElement, enum: List<Any?>, path: String, vc: VCtx): JsonElement {
    val members = enum.map { it?.toString() ?: "null" }
    if (!value.isJsonPrimitive || value.asJsonPrimitive.isBoolean) {
        vc.errors.add("$path: expected one of [${members.joinToString(", ")}], got ${jtype(value)}"); return value
    }
    val s = value.asString
    if (s in members) return value
    members.firstOrNull { it.equals(s, ignoreCase = true) }?.let {
        vc.fixes.add("$path: '$s' → '$it' (enum case)"); return JsonPrimitive(it)
    }
    val hint = closest(s, members)?.let { " (did you mean '$it'?)" } ?: ""
    vc.warns.add("$path: '$s' not in enum [${members.joinToString(", ")}]$hint — sending as-is")
    return value
}

/** Coerce a scalar toward the schema-declared primitive type. Returns the (possibly replaced) element. */
fun coerceScalar(value: JsonElement, target: String, path: String, vc: VCtx): JsonElement {
    if (value.isJsonNull) return value
    if (value.isJsonObject || value.isJsonArray) { vc.errors.add("$path: expected $target, got ${jtype(value)}"); return value }
    val p = value.asJsonPrimitive
    when (target) {
        "integer" -> {
            if (p.isNumber) {
                val bd = try { BigDecimal(p.asString) } catch (_: Exception) { null }
                if (bd != null && bd.stripTrailingZeros().scale() <= 0) return JsonPrimitive(bd.toBigIntegerExact() as BigInteger)
                vc.errors.add("$path: expected integer, got non-integral number ${redactVal(path, p.asString)}"); return value
            }
            if (p.isString) {
                val s = p.asString.trim(); val bi = s.toBigIntegerOrNull()
                if (bi != null) { vc.fixes.add("$path: \"${redactVal(path, s)}\" → ${redactVal(path, s)} (string→integer)"); return JsonPrimitive(bi) }
                vc.errors.add("$path: expected integer, got string \"${redactVal(path, s)}\""); return value
            }
            vc.errors.add("$path: expected integer, got boolean"); return value
        }
        "number" -> {
            if (p.isNumber) return value
            if (p.isString) {
                val s = p.asString.trim(); val bd = s.toBigDecimalOrNull()
                if (bd != null) { vc.fixes.add("$path: \"${redactVal(path, s)}\" → ${redactVal(path, s)} (string→number)"); return JsonPrimitive(bd) }
                vc.errors.add("$path: expected number, got string \"${redactVal(path, s)}\""); return value
            }
            vc.errors.add("$path: expected number, got boolean"); return value
        }
        "boolean" -> {
            if (p.isBoolean) return value
            if (p.isString) when (p.asString.trim().lowercase()) {
                "true" -> { vc.fixes.add("$path: \"${p.asString}\" → true (string→boolean)"); return JsonPrimitive(true) }
                "false" -> { vc.fixes.add("$path: \"${p.asString}\" → false (string→boolean)"); return JsonPrimitive(false) }
                else -> { vc.errors.add("$path: expected boolean, got string \"${redactVal(path, p.asString)}\""); return value }
            }
            vc.errors.add("$path: expected boolean, got number ${redactVal(path, p.asString)}"); return value
        }
        "string" -> {
            if (p.isString) return value
            vc.fixes.add("$path: ${redactVal(path, p.asString)} → \"${redactVal(path, p.asString)}\" (${jtype(value)}→string)")
            return JsonPrimitive(p.asString)
        }
        else -> return value
    }
}

/** Recursively validate + coerce a Gson tree against an OpenAPI schema; mutates objects/arrays in place. */
fun validate(spec: Map<String, Any?>, schemaRaw: Any?, value: JsonElement, path: String, vc: VCtx, depth: Int): JsonElement {
    if (depth > 32) return value
    val schema = asMap(resolveRef(spec, schemaRaw)) ?: return value        // unknown/empty schema → accept anything
    asList(schema["enum"])?.let { return coerceEnum(value, it, path, vc) }
    return when (schema["type"] as? String) {
        "object" -> validateObject(spec, schema, value, path, vc, depth)
        "array" -> validateArray(spec, schema, value, path, vc, depth)
        "integer", "number", "boolean", "string" -> coerceScalar(value, schema["type"] as String, path, vc)
        else -> value                                                      // untyped → accept
    }
}

fun validateObject(spec: Map<String, Any?>, schema: Map<String, Any?>, value: JsonElement, path: String, vc: VCtx, depth: Int): JsonElement {
    if (value.isJsonNull) return value
    if (!value.isJsonObject) { vc.errors.add("${path.ifEmpty { "body" }}: expected object, got ${jtype(value)}"); return value }
    val obj = value.asJsonObject
    val props = asMap(schema["properties"]) ?: emptyMap()
    val addProps = schema["additionalProperties"]                          // Map (schema) | Boolean | absent
    for (r in (asList(schema["required"])?.mapNotNull { it as? String } ?: emptyList())) {
        if (!obj.has(r) || obj.get(r).isJsonNull) vc.errors.add("${jpath(path, r)}: missing required field${typeHint(spec, props[r])}")
    }
    for (k in obj.keySet().toList()) {
        val childSchema = props[k]
        when {
            childSchema != null -> obj.add(k, validate(spec, childSchema, obj.get(k), jpath(path, k), vc, depth + 1))
            asMap(addProps) != null -> obj.add(k, validate(spec, addProps, obj.get(k), jpath(path, k), vc, depth + 1))
            addProps == true || addProps == false -> {}                     // additionalProperties:true → accept; :false is not used in this spec
            else -> {
                val hint = closest(k, props.keys)?.let { " (did you mean '$it'?)" } ?: ""
                vc.warns.add("${jpath(path, k)}: unknown field$hint — sending as-is")
            }
        }
    }
    return value
}

fun validateArray(spec: Map<String, Any?>, schema: Map<String, Any?>, value: JsonElement, path: String, vc: VCtx, depth: Int): JsonElement {
    if (value.isJsonNull) return value
    val arr = if (value.isJsonArray) value.asJsonArray
    else JsonArray().also { it.add(value); vc.fixes.add("$path: wrapped ${jtype(value)} in a 1-element array") }
    val items = schema["items"]
    if (asMap(resolveRef(spec, items)).isNullOrEmpty()) return arr          // items:{} or none → accept any element
    for (i in 0 until arr.size()) arr.set(i, validate(spec, items, arr.get(i), "$path[$i]", vc, depth + 1))
    return arr
}

/** Light type-check of path/query params (integer/number). Bad values warn (URL is still faithful), never block. */
fun checkParams(spec: Map<String, Any?>, op: Map<String, Any?>, opts: Map<String, String>, vc: VCtx) {
    for (pAny in (asList(op["parameters"]) ?: return)) {
        val p = asMap(pAny) ?: continue
        val name = p["name"] as? String ?: continue
        val v = opts["--$name"]?.trim() ?: continue
        when (asMap(resolveRef(spec, p["schema"]))?.get("type") as? String) {
            "integer" -> if (v.toBigIntegerOrNull() == null) vc.warns.add("--$name: expected integer, got \"$v\" — sending as-is")
            "number" -> if (v.toBigDecimalOrNull() == null) vc.warns.add("--$name: expected number, got \"$v\" — sending as-is")
        }
    }
}

fun printDiag(vc: VCtx) {
    vc.fixes.forEach { err("fix: $it") }
    vc.warns.forEach { err("warn: $it") }
    vc.errors.forEach { err("error: $it") }
}

// ---------------------------------------------------------------------------- request pipeline
// The single-command flow and the batch loop share the SAME two steps so behavior can't drift:
//   prepareRequest() — offline: build URL + validate/coerce the body. No network, no login, never exits.
//   dispatch()       — network: build body bytes, send, cache auth tokens, classify text vs binary.
// prepareRequest never calls die(); a hard problem is returned as `block=(exitCode,message)`.

/** Strict numeric option: absent → default; present-but-unparseable → usage error (mirrors --format). */
fun <T : Number> numOrDie(raw: String?, name: String, parse: (String) -> T?, default: T): T {
    if (raw == null) return default
    return parse(raw.trim()) ?: die(EX_USAGE, "$name must be numeric, got \"$raw\"")
}

fun emitResult(res: RunResult, o: OutOpts) {
    if (res.bytes != null) emitBytes(res.bytes, res.contentType, o) else emit(res.body, o)
}

fun clearTokenCache() {
    try { Files.newDirectoryStream(stateDir(), "token-*.json").use { s -> s.forEach { Files.deleteIfExists(it) } } } catch (_: Exception) {}
}
/** True when the token comes from an env/file override (BOOKFUSION_TOKEN[_FILE] / --token-file) — not auto-refreshable. */
fun tokenIsOverridden(opts: Map<String, String>): Boolean =
    !System.getenv("BOOKFUSION_TOKEN").isNullOrBlank() || opts["--token-file"] != null || !System.getenv("BOOKFUSION_TOKEN_FILE").isNullOrBlank()

// Real API: createSeries/createBookshelf/createReaderPreset require a client-generated `creation_token`
// (idempotency key). We auto-generate one when omitted so a bare create doesn't hard-fail validation.
val CREATION_TOKEN_CMDS = setOf("createSeries", "createBookshelf", "createReaderPreset")
fun injectCreationToken(cmd: Cmd, rawBody: String?): String? {
    if (cmd.id !in CREATION_TOKEN_CMDS || rawBody == null) return rawBody
    val el = parseOrNull(rawBody) ?: return rawBody
    if (!el.isJsonObject) return rawBody
    val o = el.asJsonObject
    val cur = o.get("creation_token")
    val missing = cur == null || cur.isJsonNull || (cur.isJsonPrimitive && cur.asString.isBlank())
    if (!missing) return rawBody
    o.addProperty("creation_token", UUID.randomUUID().toString())
    err("note: injected client-generated creation_token for ${cmd.id}")
    return GSON.toJson(o)
}

data class Prepared(
    val url: String,
    val outBody: String?,
    val vc: VCtx,
    val block: Pair<Int, String>?,   // non-null => do NOT send: (exitCode, message)
    val forceable: Boolean,          // true when the block is a validation error (--force can override)
)

fun prepareRequest(cmd: Cmd, opts: Map<String, String>, flags: Set<String>, rawBody: String?, baseUrl: String): Prepared {
    val vc = VCtx()
    var path = cmd.path
    for (p in cmd.pathParams) {
        val v = opts["--$p"] ?: return Prepared("", rawBody, vc, EX_USAGE to "missing required path param --$p for ${cmd.id}", false)
        path = path.replace("{$p}", enc(v))
    }
    val query = cmd.queryParams.mapNotNull { q -> opts["--$q"]?.let { "$q=${enc(it)}" } }.joinToString("&")
    val url = baseUrl + path + (if (query.isNotEmpty()) "?$query" else "")
    var outBody: String? = rawBody
    val doValidate = "--no-validate" !in flags
    val validatable = cmd.hasBody || cmd.multipart || cmd.pathParams.isNotEmpty() || cmd.queryParams.isNotEmpty()
    if (doValidate && validatable) {
        val spec = loadSpec(opts["--spec"])
        val op = spec?.let { operationNode(it, cmd) }
        when {
            spec == null -> err("note: spec unavailable; skipping request validation")
            op == null -> err("note: no spec entry for ${cmd.method} ${cmd.path}; skipping request validation")
            else -> {
                checkParams(spec, op, opts, vc)
                val tree = if (cmd.hasBody || cmd.multipart) rawBody?.let { parseOrNull(it) } else null
                if (tree != null) requestSchema(spec, op, cmd.multipart)?.let { sch ->
                    outBody = GSON.toJson(validate(spec, sch, tree, "", vc, 0))   // coercions reach the wire
                }
            }
        }
    }
    val block = if (vc.errors.isNotEmpty() && "--force" !in flags)
        (EX_USAGE to "fix the body, or re-run with --force (send anyway) / --no-validate (skip checks)") else null
    return Prepared(url, outBody, vc, block, vc.errors.isNotEmpty())
}

data class RunResult(
    val status: String,        // "ok" | "error"
    val http: Int?,            // HTTP status, or null when the request was never sent
    val body: String,          // decoded text body ("" when binary or not sent)
    val contentType: String?,
    val bytes: ByteArray?,     // non-null when the response body is binary
    val error: String?,        // reason when status=="error" and nothing was sent
    val exitCode: Int,
)

fun dispatch(cmd: Cmd, opts: Map<String, String>, prep: Prepared, ctx: Ctx): RunResult {
    prep.block?.let { return RunResult("error", null, "", null, null, it.second, it.first) }
    val rawBody = prep.outBody
    val bodyBytes: ByteArray?
    val contentType: String?
    if (cmd.multipart) {
        val filePath = opts["--file"]
        if (filePath != null && !Files.exists(Paths.get(expandTilde(filePath))))
            return RunResult("error", null, "", null, null, "--file not found: $filePath", EX_USAGE)
        val mp = multipartBody(rawBody ?: "{}", filePath, cmd.filePart)
        bodyBytes = mp.first; contentType = mp.second
    } else if (rawBody != null) {
        bodyBytes = rawBody.toByteArray(); contentType = "application/json"
    } else { bodyBytes = null; contentType = null }
    val resp = send(ctx, cmd.method, prep.url, bodyBytes, contentType)
    val code = resp.statusCode()
    val ct = resp.headers().firstValue("content-type").orElse(null)
    // Cache a token returned by an auth command; never let it reach output.
    if (cmd.id in AUTH_CMDS && code in 200..299) {
        parseOrNull(bodyText(resp))?.let { p ->
            if (p.isJsonObject) p.asJsonObject.get("token")?.takeIf { !it.isJsonNull }?.asString?.ifBlank { null }?.let { tok ->
                val cache = JsonObject().apply { addProperty("token", tok); addProperty("savedAt", System.currentTimeMillis()) }
                writePrivate(tokenCachePath(ctx.baseUrl, null), GSON.toJson(cache))
                err("note: response contained a token — cached; it is redacted from output")
            }
        }
    }
    val st = if (code in 200..299) "ok" else "error"
    return if (isTextResponse(ct)) RunResult(st, code, bodyText(resp), ct, null, null, EX_OK)
    else RunResult(st, code, "", ct, resp.body(), null, EX_OK)
}

// ---------------------------------------------------------------------------- batch (one JVM, one login, many ops)
data class BatchOp(val command: String, val pathId: String?, val lineOpts: Map<String, String>, val rawBody: String?)

/** Parse one JSONL line: {"command":..,"<pathparam>":..,"data":{..},"file":".."}. Returns null on malformed input. */
fun parseBatchLine(line: String): BatchOp? {
    val el = parseOrNull(line) ?: return null
    if (!el.isJsonObject) return null
    val o = el.asJsonObject
    val command = o.get("command")?.takeIf { it.isJsonPrimitive }?.asString ?: return null
    val lineOpts = mutableMapOf<String, String>()
    var pathId: String? = null
    for ((k, v) in o.entrySet()) {
        when (k) {
            "command", "data" -> {}
            "file" -> if (!v.isJsonNull) lineOpts["--file"] = v.asString
            else -> if (!v.isJsonNull) {
                val s = if (v.isJsonPrimitive) v.asString else GSON.toJson(v)
                lineOpts["--$k"] = s
                if (k == "id" || k == "number") pathId = s
            }
        }
    }
    val data = o.get("data")
    val rawBody = if (data != null && !data.isJsonNull) GSON.toJson(data) else null
    return BatchOp(command, pathId, lineOpts, rawBody)
}

fun batchBody(cmd: Cmd, rawBody: String?): String? = if (!cmd.hasBody && !cmd.multipart) null else (rawBody ?: "{}")

fun runBatch(baseUrl: String, minIntervalMs: Long, device: String, opts: Map<String, String>, flags: Set<String>): Nothing {
    if ("--continue-on-error" in flags && "--stop-on-error" in flags)
        die(EX_USAGE, "choose only one of --continue-on-error / --stop-on-error")
    val stopOnError = "--stop-on-error" in flags
    var token = ensureToken(baseUrl, minIntervalMs, device, opts)   // ONE login for the whole batch
    var reauthed = false
    var n = 0; var okN = 0; var errN = 0
    val reader = System.`in`.bufferedReader()
    while (true) {
        val line = reader.readLine() ?: break
        if (line.isBlank()) continue
        n++
        val out = JsonObject().apply { addProperty("line", n) }
        fun fail(msg: String) { out.addProperty("status", "error"); out.addProperty("error", msg); println(GSON.toJson(out)); errN++ }
        val op = parseBatchLine(line)
        if (op == null) { fail("invalid JSON or missing 'command'"); if (stopOnError) break else continue }
        out.addProperty("command", op.command); op.pathId?.let { out.addProperty("id", it) }
        if (op.command in EXCLUDED) { fail("excluded command"); if (stopOnError) break else continue }
        val cmd = REGISTRY[op.command]
        if (cmd == null) { fail("unknown command"); if (stopOnError) break else continue }
        if (cmd.tier == Tier.DANGEROUS && "--dangerous" !in flags) { fail("DANGEROUS — re-run batch with --dangerous"); if (stopOnError) break else continue }
        val body = injectCreationToken(cmd, batchBody(cmd, op.rawBody))
        val prep = prepareRequest(cmd, op.lineOpts, flags, body, baseUrl)
        printDiag(prep.vc)
        var res = dispatch(cmd, op.lineOpts, prep, Ctx(baseUrl, minIntervalMs, token, device))
        if (res.http == 401 && cmd.id !in AUTH_CMDS && !reauthed && !tokenIsOverridden(opts)) {
            err("note: token rejected (401); clearing cache and re-authenticating once for the batch")
            clearTokenCache(); reauthed = true
            token = ensureToken(baseUrl, minIntervalMs, device, opts)
            res = dispatch(cmd, op.lineOpts, prep, Ctx(baseUrl, minIntervalMs, token, device))
        }
        out.addProperty("status", res.status); res.http?.let { out.addProperty("http", it) }; res.error?.let { out.addProperty("error", it) }
        println(GSON.toJson(out))
        if (res.status == "ok") okN++ else { errN++; if (stopOnError) break }
    }
    err("batch: $n ops, $okN ok, $errN error")
    exitProcess(if (errN > 0) EX_HTTP else EX_OK)
}

// ---------------------------------------------------------------------------- main
val (command, opts, flags) = parse(args.toList())

val baseUrl = (opts["--base-url"] ?: System.getenv("BOOKFUSION_BASE_URL") ?: DEFAULT_BASE).trimEnd('/')
val rate = numOrDie(opts["--rate"] ?: System.getenv("BOOKFUSION_RATE_LIMIT"), "--rate", { it.toDoubleOrNull() }, DEFAULT_RATE)
val minIntervalMs = if (rate <= 0) 0L else Math.round(1000.0 / rate)
val maxBytes = numOrDie(opts["--max-bytes"] ?: System.getenv("BOOKFUSION_OUTPUT_MAX_BYTES"), "--max-bytes", { it.toIntOrNull() }, DEFAULT_MAX_BYTES)
val pretty = "--pretty" in flags
val device = deviceId()
val fmt = (opts["--format"] ?: System.getenv("BOOKFUSION_FORMAT") ?: "auto").lowercase()
if (fmt !in setOf("auto", "tsv", "jsonl", "json")) die(EX_USAGE, "--format must be auto|tsv|jsonl|json")
val outOpts = OutOpts(fmt, pretty, maxBytes, numOrDie(opts["--preview-lines"], "--preview-lines", { it.toIntOrNull() }, 10), "--stdout" in flags, opts["--out"])

if (command == null || command == "help" || "--help" in flags || "-h" in flags) { println(usage()); exitProcess(EX_OK) }

when (command) {
    "list" -> { println(listCommands()); exitProcess(EX_OK) }
    "logout" -> {
        var n = 0
        Files.newDirectoryStream(stateDir(), "token-*.json").use { s -> s.forEach { Files.deleteIfExists(it); n++ } }
        err("cleared $n cached token(s)"); exitProcess(EX_OK)
    }
    "login" -> {
        doLogin(baseUrl, minIntervalMs, device, opts)
        println("""{"status":"ok","message":"logged in, token cached"}""".let { if (pretty) PRETTY.toJson(JsonParser.parseString(it)) else it })
        exitProcess(EX_OK)
    }
    "batch" -> runBatch(baseUrl, minIntervalMs, device, opts, flags)   // reads JSONL from stdin; never returns
}

val cmdName = if (command == "whoami") "getUser" else command
if (cmdName in EXCLUDED) die(EX_GATED, "'$cmdName' is intentionally EXCLUDED (${EXCLUDED[cmdName]}). It is not available in this skill.")
val cmd = REGISTRY[cmdName] ?: die(EX_USAGE, "unknown command: $command  (run `bookfusion list`)")

if (cmd.tier == Tier.DANGEROUS && "--dangerous" !in flags)
    die(EX_GATED, "'${cmd.id}' is DANGEROUS (${cmd.method} ${cmd.path}). Re-run with --dangerous to proceed.")

// prepare (offline): build URL + validate/coerce the body — no network, no login yet.
val rawBodyStr = injectCreationToken(cmd, readBody(cmd, opts, flags))
val prep = prepareRequest(cmd, opts, flags, rawBodyStr, baseUrl)
printDiag(prep.vc)

// --dry-run: report the (validated, coerced) request and stop — never touches the network or auto-login.
if ("--dry-run" in flags) {
    err("dry-run: ${prep.vc.fixes.size} fixes, ${prep.vc.warns.size} warns, ${prep.vc.errors.size} errors; would ${cmd.method} ${prep.url}")
    prep.outBody?.let { b -> parseOrNull(b)?.let { println(if (pretty) PRETTY.toJson(redactTree(it)) else GSON.toJson(redactTree(it))) } }
    exitProcess(if (prep.vc.errors.isNotEmpty()) EX_USAGE else EX_OK)
}
// Default: block a definitely-malformed request before the round trip. --force sends anyway.
if (prep.block != null) {
    if (prep.forceable && "--force" in flags) err("note: --force set; sending despite ${prep.vc.errors.size} validation error(s)")
    else die(prep.block.first, "hint: ${prep.block.second}")
}

// auth: attach token unless this is an auth/public command
val token = if (cmd.id in AUTH_CMDS) (cachedToken(baseUrl, null, opts) ?: "") else ensureToken(baseUrl, minIntervalMs, device, opts)
var res = dispatch(cmd, opts, prep, Ctx(baseUrl, minIntervalMs, token, device))

// stale cached token → clear cache + re-authenticate once (env/file token overrides are not auto-refreshable)
if (res.http == 401 && cmd.id !in AUTH_CMDS && !tokenIsOverridden(opts)) {
    err("note: token rejected (401); clearing cache and re-authenticating once")
    clearTokenCache()
    res = dispatch(cmd, opts, prep, Ctx(baseUrl, minIntervalMs, ensureToken(baseUrl, minIntervalMs, device, opts), device))
}

if (res.http == null) { res.error?.let { err(it) }; exitProcess(res.exitCode) }   // never sent (e.g. bad --file)
if (res.http !in 200..299) {
    err("HTTP ${res.http} for ${cmd.method} ${cmd.path}")
    emitResult(res, outOpts)
    exitProcess(if (res.http == 401 && cmd.id !in AUTH_CMDS) EX_AUTH else EX_HTTP)
}
// success — --quiet suppresses the (large) body echo for non-SAFE writes; errors above still print
if ("--quiet" in flags && cmd.tier != Tier.SAFE) err("ok: ${cmd.id} -> HTTP ${res.http}")
else emitResult(res, outOpts)
exitProcess(EX_OK)
