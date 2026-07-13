#!/usr/bin/env kotlin
@file:Repository("https://repo1.maven.org/maven2")
@file:DependsOn("com.google.code.gson:gson:2.11.0")

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
import java.io.RandomAccessFile
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
    Cmd("createHighlight", "POST", "/api/user/highlights", Tier.WRITE, listOf(), listOf(), true, true),
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
    val path = Paths.get(p.replaceFirst("~", System.getProperty("user.home")))
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
            val wait = last + minIntervalMs - System.currentTimeMillis()
            if (wait > 0) Thread.sleep(wait)
            val now = System.currentTimeMillis()
            raf.setLength(0); raf.seek(0); raf.writeBytes(now.toString())
        }
    }
}

// ---------------------------------------------------------------------------- HTTP
val CLIENT: HttpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(20)).build()

data class Ctx(val baseUrl: String, val minIntervalMs: Long, val token: String, val device: String)

fun send(ctx: Ctx, method: String, url: String, body: ByteArray?, contentType: String?): HttpResponse<String> {
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
    return try { CLIENT.send(b.build(), HttpResponse.BodyHandlers.ofString()) }
    catch (e: Exception) { die(EX_IO, "network error: ${e.message}") }
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
    val obj = try { JsonParser.parseString(resp.body()).asJsonObject } catch (_: Exception) { JsonObject() }
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
fun isSensitiveKey(k: String): Boolean { val l = k.lowercase(); return l in SENSITIVE_KEYS || l.contains("password") }

fun parseOrNull(s: String): JsonElement? = try { JsonParser.parseString(s) } catch (_: Exception) { null }

fun treeHasSensitive(e: JsonElement?): Boolean = when {
    e == null -> false
    e.isJsonObject -> e.asJsonObject.entrySet().any { isSensitiveKey(it.key) || treeHasSensitive(it.value) }
    e.isJsonArray -> e.asJsonArray.any { treeHasSensitive(it) }
    else -> false
}
fun redactTree(e: JsonElement): JsonElement = when {
    e.isJsonObject -> JsonObject().also { o ->
        e.asJsonObject.entrySet().forEach { (k, v) ->
            o.add(k, if (isSensitiveKey(k)) JsonPrimitive("***REDACTED***") else redactTree(v))
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

// ---------------------------------------------------------------------------- multipart
fun multipartBody(payloadJson: String, filePath: String?): Pair<ByteArray, String> {
    val boundary = "----bookfusion" + UUID.randomUUID().toString().replace("-", "")
    val out = java.io.ByteArrayOutputStream()
    fun w(s: String) = out.write(s.toByteArray(StandardCharsets.UTF_8))
    w("--$boundary\r\n")
    w("Content-Disposition: form-data; name=\"payload\"\r\n")
    w("Content-Type: application/json\r\n\r\n")
    w(payloadJson); w("\r\n")
    if (filePath != null) {
        val f = Paths.get(filePath)
        if (!Files.exists(f)) die(EX_USAGE, "--file not found: $filePath")
        val name = f.fileName.toString()
        w("--$boundary\r\n")
        w("Content-Disposition: form-data; name=\"file\"; filename=\"$name\"\r\n")
        w("Content-Type: application/octet-stream\r\n\r\n")
        out.write(Files.readAllBytes(f)); w("\r\n")
    }
    w("--$boundary--\r\n")
    return out.toByteArray() to "multipart/form-data; boundary=$boundary"
}

// ---------------------------------------------------------------------------- arg parsing
val BOOL_FLAGS = setOf("--dangerous", "--pretty", "--data-stdin", "--stdout", "--help", "-h")
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
  bookfusion login | logout | whoami | list | help

FLAGS:
  --dangerous            required to run a DANGEROUS (destructive) command
  --data '<json>'        request body (also --data-file PATH, --data-stdin)
  --file PATH            binary part for multipart commands (upload/cover/highlight image)
  --format F             output format: auto (default) | tsv | jsonl | json (env BOOKFUSION_FORMAT)
  --pretty               pretty-print JSON output
  --stdout               force full output inline (only for small, non-credential responses)
  --out PATH             write the full response to PATH instead of a temp file
  --preview-lines N      lines of redacted preview to show for filed output (default 10; 0 = none)
  --max-bytes N          inline size limit; larger responses go to a temp file (env BOOKFUSION_OUTPUT_MAX_BYTES)
  --base-url URL         override API base (env BOOKFUSION_BASE_URL; default $DEFAULT_BASE)
  --rate N               max requests/sec (env BOOKFUSION_RATE_LIMIT; default $DEFAULT_RATE)
  --<pathparam> V        e.g. --id 123 --number 456 --slug foo --book_id 789 --email a@b.c

OUTPUT (context economy): lists render as compact TSV by default; large responses and any response
containing credentials are written to a temp file (0600 for credentials) — stdout then carries only the
file path plus a short redacted preview on stderr. Sensitive keys (token/password/…) are never printed.

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

// ---------------------------------------------------------------------------- main
val (command, opts, flags) = parse(args.toList())

val baseUrl = (opts["--base-url"] ?: System.getenv("BOOKFUSION_BASE_URL") ?: DEFAULT_BASE).trimEnd('/')
val rate = (opts["--rate"] ?: System.getenv("BOOKFUSION_RATE_LIMIT"))?.toDoubleOrNull() ?: DEFAULT_RATE
val minIntervalMs = if (rate <= 0) 0L else Math.round(1000.0 / rate)
val maxBytes = (opts["--max-bytes"] ?: System.getenv("BOOKFUSION_OUTPUT_MAX_BYTES"))?.toIntOrNull() ?: DEFAULT_MAX_BYTES
val pretty = "--pretty" in flags
val device = deviceId()
val fmt = (opts["--format"] ?: System.getenv("BOOKFUSION_FORMAT") ?: "auto").lowercase()
if (fmt !in setOf("auto", "tsv", "jsonl", "json")) die(EX_USAGE, "--format must be auto|tsv|jsonl|json")
val outOpts = OutOpts(fmt, pretty, maxBytes, opts["--preview-lines"]?.toIntOrNull() ?: 10, "--stdout" in flags, opts["--out"])

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
}

val cmdName = if (command == "whoami") "getUser" else command
if (cmdName in EXCLUDED) die(EX_GATED, "'$cmdName' is intentionally EXCLUDED (${EXCLUDED[cmdName]}). It is not available in this skill.")
val cmd = REGISTRY[cmdName] ?: die(EX_USAGE, "unknown command: $command  (run `bookfusion list`)")

if (cmd.tier == Tier.DANGEROUS && "--dangerous" !in flags)
    die(EX_GATED, "'${cmd.id}' is DANGEROUS (${cmd.method} ${cmd.path}). Re-run with --dangerous to proceed.")

// build path (substitute {param}) and query string
var path = cmd.path
for (p in cmd.pathParams) {
    val v = opts["--$p"] ?: die(EX_USAGE, "missing required path param --$p for ${cmd.id}")
    path = path.replace("{$p}", enc(v))
}
val query = cmd.queryParams.mapNotNull { q -> opts["--$q"]?.let { "$q=${enc(it)}" } }.joinToString("&")
val url = baseUrl + path + (if (query.isNotEmpty()) "?$query" else "")

// auth: attach token unless this is an auth/public command
val token = if (cmd.id in AUTH_CMDS) (cachedToken(baseUrl, null, opts) ?: "") else ensureToken(baseUrl, minIntervalMs, device, opts)
val ctx = Ctx(baseUrl, minIntervalMs, token, device)

// body
val rawBody = readBody(cmd, opts, flags)
val (bodyBytes, contentType) = when {
    cmd.multipart -> multipartBody(rawBody ?: "{}", opts["--file"])
    rawBody != null -> rawBody.toByteArray() to "application/json"
    else -> null to null
}

val resp = send(ctx, cmd.method, url, bodyBytes, contentType)

// If an auth command returned a token, cache it and do NOT let it reach the terminal/context.
if (cmd.id in AUTH_CMDS && resp.statusCode() in 200..299) {
    parseOrNull(resp.body())?.let { p ->
        if (p.isJsonObject) p.asJsonObject.get("token")?.takeIf { !it.isJsonNull }?.asString?.ifBlank { null }?.let { tok ->
            val cache = JsonObject().apply { addProperty("token", tok); addProperty("savedAt", System.currentTimeMillis()) }
            writePrivate(tokenCachePath(baseUrl, null), GSON.toJson(cache))
            err("note: response contained a token — cached; it is redacted from output")
        }
    }
}

if (resp.statusCode() !in 200..299) {
    err("HTTP ${resp.statusCode()} for ${cmd.method} $path")
    emit(resp.body(), outOpts)
    exitProcess(EX_HTTP)
}
emit(resp.body(), outOpts)
exitProcess(EX_OK)
