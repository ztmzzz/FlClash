package com.follow.mitmtest

import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class MitmE2ETest {
    private val host: String by lazy {
        InstrumentationRegistry.getArguments().getString("mitmHost") ?: "mitm.test"
    }

    companion object {
        private lateinit var server: MockWebServer
        private lateinit var directClient: OkHttpClient
        private val hits = AtomicInteger(0)
        private var port: Int = 0

        @JvmStatic
        @BeforeClass
        fun beforeClass() {
            val heldCertificate =
                HeldCertificate.Builder()
                    .commonName("mitm.test")
                    .addSubjectAlternativeName("mitm.test")
                    .build()
            val serverCertificates =
                HandshakeCertificates.Builder()
                    .heldCertificate(heldCertificate)
                    .build()

            val directTrust =
                HandshakeCertificates.Builder()
                    .addTrustedCertificate(heldCertificate.certificate)
                    .build()

            directClient = OkHttpClient.Builder()
                .sslSocketFactory(directTrust.sslSocketFactory(), directTrust.trustManager)
                .hostnameVerifier { _, _ -> true }
                .protocols(listOf(Protocol.HTTP_1_1))
                .connectTimeout(5, TimeUnit.SECONDS)
                .writeTimeout(15, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .callTimeout(20, TimeUnit.SECONDS)
                .build()

            server = MockWebServer()
            server.useHttps(serverCertificates.sslSocketFactory(), false)
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse {
                        val path = request.requestUrl?.encodedPath ?: "/"
                        if (path != "/hits") {
                            hits.incrementAndGet()
                        }

                        if (path == "/hits") {
                            val payload = JSONObject().put("hits", hits.get()).toString()
                            return MockResponse()
                                .setResponseCode(200)
                                .setHeader("Content-Type", "application/json")
                                .setBody(payload)
                        }

                        if (path == "/big") {
                            val payload =
                                JSONObject()
                                    .put("ok", true)
                                    .put("path", request.path ?: "")
                                    .put("data", "x".repeat(8000))
                                    .toString()
                            return MockResponse()
                                .setResponseCode(200)
                                .setHeader("Content-Type", "application/json")
                                .setHeader("X-Upstream", "big")
                                .setBody(payload)
                        }

                        val reqHeaders = JSONObject()
                        for (name in request.headers.names()) {
                            reqHeaders.put(name, request.getHeader(name) ?: "")
                        }

                        val payload =
                            JSONObject()
                                .put("ok", true)
                                .put("path", request.path ?: "")
                                .put("req_headers", reqHeaders)
                                .toString()

                        return MockResponse()
                            .setResponseCode(200)
                            .setHeader("Content-Type", "application/json")
                            .setHeader("X-Upstream", "ok")
                            .setBody(payload)
                    }
                }

            // Bind on loopback so Clash(hosts: mitm.test -> 127.0.0.1) can reach it.
            server.start(InetAddress.getByName("127.0.0.1"), 0)
            port = server.port

        }

        @JvmStatic
        @AfterClass
        fun afterClass() {
            runCatching { server.shutdown() }
        }
    }

    private fun client(): OkHttpClient {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 7890))
        return OkHttpClient.Builder()
            .proxy(proxy)
            .protocols(listOf(Protocol.HTTP_1_1))
            .connectTimeout(5, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(12, TimeUnit.SECONDS)
            .build()
    }

    private data class HttpResult(
        val code: Int,
        val headers: Map<String, String>,
        val body: String,
    )

    private fun header(headers: Map<String, String>, name: String): String? {
        return headers[name.lowercase()]
    }

    private fun get(path: String, extraHeaders: Map<String, String> = emptyMap()): HttpResult {
        val builder = Request.Builder()
            .url("https://$host:$port$path")
            .header("User-Agent", "FlClash-MITM-Test")
            .header("X-Client", "1")

        for ((k, v) in extraHeaders) {
            builder.header(k, v)
        }

        val request = builder.build()

        var lastBody = ""
        var lastErr: Throwable? = null
        repeat(6) { attempt ->
            try {
                client().newCall(request).execute().use { resp ->
                    lastBody = resp.body?.string() ?: ""
                    val headers = mutableMapOf<String, String>()
                    for (name in resp.headers.names()) {
                        headers[name.lowercase()] = resp.header(name).orEmpty()
                    }
                    return HttpResult(resp.code, headers, lastBody)
                }
            } catch (t: Throwable) {
                lastErr = t
                Thread.sleep(300L + (attempt * 250L))
            }
        }
        throw AssertionError(
            "request failed after retries, lastErr=${lastErr?.javaClass?.name}: ${lastErr?.message}, lastBody=$lastBody",
            lastErr,
        )
    }

    private fun runWithRetry(label: String, attempts: Int = 3, block: () -> Unit) {
        var lastErr: Throwable? = null
        repeat(attempts) { attempt ->
            try {
                block()
                return
            } catch (t: Throwable) {
                lastErr = t
                if (attempt < attempts - 1) {
                    Thread.sleep(1000L + (attempt * 700L))
                }
            }
        }
        throw AssertionError("$label failed after retries", lastErr)
    }

    private fun jsonGet(path: String): JSONObject {
        val r = get(path)
        assertEquals("unexpected http code, body=${r.body}", 200, r.code)
        return JSONObject(r.body)
    }

    private fun hitsCount(): Int {
        val request = Request.Builder()
            .url("https://127.0.0.1:$port/hits")
            .build()
        directClient.newCall(request).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            assertEquals("unexpected hits code, body=$body", 200, resp.code)
            return JSONObject(body).optInt("hits", -1)
        }
    }

    private fun findHeaderCaseInsensitive(headers: JSONObject, name: String): String? {
        val target = name.lowercase()
        val it = headers.keys()
        while (it.hasNext()) {
            val k = it.next()
            if (k.lowercase() == target) {
                val v = headers.opt(k)
                return v?.toString()
            }
        }
        return null
    }

    @Test
    fun test01_http11_mitm_modifies_request_and_response() {
        runWithRetry("test01_http11_mitm_modifies_request_and_response") {
            val obj = jsonGet("/anything")

            // Request header modifications are observable by upstream.
            val reqHeaders = obj.getJSONObject("req_headers")
            assertEquals("1", findHeaderCaseInsensitive(reqHeaders, "X-FlClash-MITM"))
            assertEquals("B", findHeaderCaseInsensitive(reqHeaders, "X-Req-Order"))

            // Response modifications are observable by client.
            val r = get("/anything")
            assertEquals("ok", header(r.headers, "X-MITM"))
            assertEquals("B", header(r.headers, "X-Resp-Order"))
            assertTrue("unexpected response body: ${r.body}", r.body.contains("\"mitm_marker\":\"ok\""))
            assertTrue("unexpected response body: ${r.body}", r.body.contains("\"order\":\"B\""))
        }
    }

    @Test
    fun test02_reply_short_circuit_returns_scripted_response() {
        runWithRetry("test02_reply_short_circuit_returns_scripted_response") {
            val before = hitsCount()
            val r = get("/reply")
            assertEquals(200, r.code)
            assertEquals("1", header(r.headers, "X-Reply"))
            assertTrue("unexpected reply body: ${r.body}", r.body.contains("\"reply\":true"))
            assertFalse("unexpected upstream response leaked: ${r.body}", r.body.contains("\"ok\":true"))
            val after = hitsCount()
            assertEquals("reply should not be forwarded upstream", before, after)
        }
    }

    @Test
    fun test03_large_body_is_forwarded_without_script_response_mods() {
        runWithRetry("test03_large_body_is_forwarded_without_script_response_mods") {
            val before = hitsCount()
            val r = get("/big")
            assertEquals(200, r.code)

            // captureMaxBytes is small, so response-phase script should be bypassed.
            assertFalse("unexpected response header X-MITM present", r.headers.containsKey("x-mitm"))
            assertFalse("unexpected response header X-Resp-Order present", r.headers.containsKey("x-resp-order"))
            assertFalse("unexpected response body modified: ${r.body.take(200)}...", r.body.contains("\"mitm_marker\":\"ok\""))

            val after = hitsCount()
            assertEquals("big response should still be forwarded upstream", before + 1, after)
        }
    }

    @Test
    fun test04_kv_store_is_exposed_to_scripts_and_persisted() {
        runWithRetry("test04_kv_store_is_exposed_to_scripts_and_persisted") {
            val r1 = get("/kv", mapOf("X-KV-Set" to "1"))
            assertEquals(200, r1.code)
            assertEquals("1", header(r1.headers, "X-KV-Count"))

            val r2 = get("/kv", mapOf("X-KV-Set" to "2"))
            assertEquals(200, r2.code)
            assertEquals("2", header(r2.headers, "X-KV-Count"))

            // No mutation: should keep the last value.
            val r3 = get("/kv")
            assertEquals(200, r3.code)
            assertEquals("2", header(r3.headers, "X-KV-Count"))
        }
    }
}
