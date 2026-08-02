package com.anymex.ios;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.net.HttpCookie;
import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource;
import eu.kanade.tachiyomi.animesource.model.AnimeFilter;
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.Filter;
import eu.kanade.tachiyomi.source.model.FilterList;
import kotlinx.coroutines.BuildersKt;
import kotlinx.coroutines.CoroutineScope;
import kotlin.coroutines.Continuation;
import kotlin.coroutines.EmptyCoroutineContext;
import kotlin.jvm.functions.Function2;

/**
 * iOS FFI entry point for the AnymeX extension runtime.
 * <p>
 * This class runs inside the embedded OpenJDK Zero JVM on iOS.
 * It receives method calls from the Swift FFI layer (which calls via JNI)
 * and delegates to the existing desktop extension loading Kotlin code.
 * <p>
 * Since the anymex_ios_runtime.jar is built with BOTH this Java class
 * AND the existing desktop Kotlin classes compiled together, we can
 * directly call the Kotlin singletons from Java.
 */
public class IosExtensionLoader {

    private static final Gson gson = new Gson();
    private static final Map<String, String> cookieStore = new HashMap<>();
    private static final Map<String, String> userAgentStore = new HashMap<>();
    private static final Map<String, Object> activeJobs = new ConcurrentHashMap<>();
    private static volatile boolean initialized = false;

    // -----------------------------------------------------------------------
    //  Public API — called from Swift via JNI
    // -----------------------------------------------------------------------

    /**
     * Initialize the runtime (Injekt singletons, OkHttp client, etc.).
     */
    public static synchronized void initialize() {
        if (initialized) return;
        System.err.println("[IosExtensionLoader] Initializing runtime...");

        try {
            // Initialize all three sub-systems
            com.anymex.desktop.AniyomiSourceMethods.initialize();
            com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.initialize();
            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.initialize();
            initialized = true;
            System.err.println("[IosExtensionLoader] Runtime initialized successfully.");
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] Runtime initialization failed: " + t.getMessage());
            t.printStackTrace();
            throw new RuntimeException("Failed to initialize IosExtensionLoader", t);
        }
    }

    /**
     * Destroy the runtime and clean up resources.
     */
    public static synchronized void destroy() {
        System.err.println("[IosExtensionLoader] Destroying runtime...");
        try {
            // Cancel all active jobs
            for (Map.Entry<String, Object> entry : activeJobs.entrySet()) {
                Object job = entry.getValue();
                if (job instanceof kotlinx.coroutines.Job) {
                    ((kotlinx.coroutines.Job) job).cancel(null);
                }
            }
            activeJobs.clear();
            cookieStore.clear();
            userAgentStore.clear();
            initialized = false;
            System.err.println("[IosExtensionLoader] Runtime destroyed.");
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] Error during destroy: " + t.getMessage());
        }
    }

    /**
     * Main dispatch method. The Swift FFI layer calls this via JNI.
     *
     * @param method   the method name (e.g. "loadExtensions", "aniyomiGetPopular")
     * @param argsJson JSON object with the method arguments
     * @return JSON string with the result
     */
    public static String callMethod(String method, String argsJson) {
        if (!initialized && !"initialize".equals(method)) {
            try {
                initialize();
            } catch (Throwable t) {
                return errorJson("Runtime not initialized: " + t.getMessage());
            }
        }

        JsonObject _args;
        try {
            _args = gson.fromJson(argsJson, JsonObject.class);
        } catch (Exception e) {
            _args = null;
        }
        final JsonObject args = (_args != null) ? _args : new JsonObject();

        try {
            switch (method) {
                // ---- Aniyomi methods ----
                case "loadExtensions":
                    return handleLoadExtensions(args);
                case "convertApk":
                    return handleConvertApk(args);
                case "aniyomiGetPopular":
                    return handleAniyomiGetPopular(args);
                case "aniyomiSearch":
                    return handleAniyomiSearch(args);
                case "aniyomiGetDetail":
                    return handleAniyomiGetDetail(args);
                case "aniyomiGetVideoList":
                    return handleAniyomiGetVideoList(args);
                case "aniyomiGetPageList":
                    return handleAniyomiGetPageList(args);
                case "aniyomiGetLatestUpdates":
                    return handleAniyomiGetLatestUpdates(args);
                case "aniyomiGetFilterList":
                    return handleAniyomiGetFilterList(args);
                case "aniyomiGetPreference":
                    return handleAniyomiGetPreference(args);
                case "aniyomiSavePreference":
                    return handleAniyomiSavePreference(args);

                // ---- CloudStream methods ----
                case "csLoadExtensions":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.loadExtensions(getString(args, "folderPath"), cont));
                case "csSearch":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.search(
                                    getString(args, "sourceId"),
                                    getString(args, "query"),
                                    getInt(args, "page", 1),
                                    cont));
                case "csGetDetail":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.fetchDetails(
                                    getString(args, "sourceId"),
                                    getString(args, "url"),
                                    cont));
                case "csGetVideoList":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.fetchVideoList(
                                    getString(args, "sourceId"),
                                    getString(args, "url"),
                                    cont));
                case "csGetRegisteredProviders":
                    return handleCsGetRegisteredProviders();
                case "csGetExtensionSettings":
                    return handleCsGetExtensionSettings(args);
                case "csSetExtensionSettings":
                    return handleCsSetExtensionSettings(args);

                // ---- Kotatsu methods ----
                case "kotatsuLoadExtensions":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.loadExtensions(
                                    getString(args, "folderPath"), cont));
                case "kotatsuGetPopular":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.getPopular(
                                    getString(args, "sourceId"),
                                    getInt(args, "page", 1),
                                    cont));
                case "kotatsuGetLatestUpdates":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.getLatestUpdates(
                                    getString(args, "sourceId"),
                                    getInt(args, "page", 1),
                                    cont));
                case "kotatsuSearch":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.search(
                                    getString(args, "sourceId"),
                                    getString(args, "query"),
                                    getInt(args, "page", 1),
                                    cont));
                case "kotatsuGetDetail":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.getDetails(
                                    getString(args, "sourceId"),
                                    getString(args, "url"),
                                    getString(args, "title"),
                                    getString(args, "cover"),
                                    cont));
                case "kotatsuGetPageList":
                    return runSuspend(args, (scope, cont) ->
                            com.anymex.desktop.kotatsu.KotatsuExtensionLoader.INSTANCE.getPageList(
                                    getString(args, "sourceId"),
                                    getString(args, "url"),
                                    getString(args, "name"),
                                    cont));

                // ---- Global methods ----
                case "cancelRequest":
                    return handleCancelRequest(args);
                case "setCookies":
                    return handleSetCookies(args);
                case "setUserAgent":
                    return handleSetUserAgent(args);
                case "cancel":
                    return handleCancel(args);
                case "ping":
                    return "\"pong\"";

                default:
                    return errorJson("Unknown method: " + method);
            }
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] Error in " + method + ": " + t.getMessage());
            t.printStackTrace();
            return errorJson(t.getMessage() != null ? t.getMessage() : t.toString());
        }
    }

    // =======================================================================
    //  Aniyomi method handlers
    // =======================================================================

    private static String handleLoadExtensions(JsonObject args) {
        String folderPath = getString(args, "folderPath");
        try {
            // AniyomiSourceMethods.loadExtensions is NOT a suspend function
            return com.anymex.desktop.AniyomiSourceMethods.INSTANCE.loadExtensions(folderPath);
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] loadExtensions error: " + t.getMessage());
            t.printStackTrace();
            return "[]";
        }
    }

    private static String handleConvertApk(JsonObject args) {
        String apkPath = getString(args, "apkPath");
        String outJarPath = getString(args, "outJarPath");
        try {
            com.anymex.desktop.ApkConverter.INSTANCE.convertApkToJar(apkPath, outJarPath);
            return gson.toJson(Map.of("success", true, "outJarPath", outJarPath));
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] convertApk error: " + t.getMessage());
            return errorJson("convertApk failed: " + t.getMessage());
        }
    }

    private static String handleAniyomiGetPopular(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        int page = getInt(args, "page", 1);
        Object isAnime = getIsAnime(args);
        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.fetchPopular(sourceId, page, isAnime, cont));
    }

    private static String handleAniyomiSearch(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        String query = getString(args, "query");
        int page = getInt(args, "page", 1);
        Object isAnime = getIsAnime(args);
        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.search(sourceId, query, page, isAnime, cont));
    }

    private static String handleAniyomiGetDetail(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        Object isAnime = getIsAnime(args);

        JsonObject media = args.getAsJsonObject("media");
        final String url, title, cover;
        if (media != null) {
            url = getString(media, "url");
            title = getString(media, "title");
            String c = getString(media, "thumbnail_url");
            cover = c.isEmpty() ? getString(media, "cover") : c;
        } else {
            url = "";
            title = "";
            cover = "";
        }

        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.fetchDetails(sourceId, url, title, cover, isAnime, cont));
    }

    private static String handleAniyomiGetVideoList(JsonObject args) {
        String sourceId = getString(args, "sourceId");

        JsonObject episode = args.getAsJsonObject("episode");
        final String url, name;
        if (episode != null) {
            url = getString(episode, "url");
            name = getString(episode, "name");
        } else {
            url = "";
            name = "";
        }

        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.fetchVideoList(sourceId, url, name, cont));
    }

    private static String handleAniyomiGetPageList(JsonObject args) {
        String sourceId = getString(args, "sourceId");

        JsonObject episode = args.getAsJsonObject("episode");
        final String url, name;
        if (episode != null) {
            url = getString(episode, "url");
            name = getString(episode, "name");
        } else {
            url = "";
            name = "";
        }

        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.fetchPageList(sourceId, url, name, cont));
    }

    private static String handleAniyomiGetLatestUpdates(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        int page = getInt(args, "page", 1);
        Object isAnime = getIsAnime(args);
        return runSuspend(args, (scope, cont) ->
                com.anymex.desktop.AniyomiSourceMethods.INSTANCE.fetchLatestUpdates(sourceId, page, isAnime, cont));
    }

    /**
     * Get the filter list for an Aniyomi source.
     * Calls getFilterList() on the loaded source and serializes the filters to JSON.
     */
    private static String handleAniyomiGetFilterList(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        boolean isAnime = getBoolean(args, "isAnime", true);

        try {
            JsonArray resultArray = new JsonArray();

            if (isAnime) {
                Object source = com.anymex.desktop.DesktopExtensionLoader.INSTANCE.getLoadedAnimeSources().get(sourceId);
                if (source instanceof AnimeCatalogueSource) {
                    AnimeFilterList filters = ((AnimeCatalogueSource) source).getFilterList();
                    if (filters != null) {
                        for (AnimeFilter<?> filter : filters) {
                            resultArray.add(serializeAnimeFilter(filter));
                        }
                    }
                }
            } else {
                Object source = com.anymex.desktop.DesktopExtensionLoader.INSTANCE.getLoadedMangaSources().get(sourceId);
                if (source instanceof CatalogueSource) {
                    FilterList filters = ((CatalogueSource) source).getFilterList();
                    if (filters != null) {
                        for (Filter<?> filter : filters) {
                            resultArray.add(serializeMangaFilter(filter));
                        }
                    }
                }
            }

            return gson.toJson(resultArray);
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] aniyomiGetFilterList error: " + t.getMessage());
            t.printStackTrace();
            return "[]";
        }
    }

    private static String handleAniyomiGetPreference(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        Object isAnime = getIsAnime(args);
        try {
            return com.anymex.desktop.AniyomiSourceMethods.INSTANCE.getPreferences(sourceId, isAnime);
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] aniyomiGetPreference error: " + t.getMessage());
            return "[]";
        }
    }

    private static String handleAniyomiSavePreference(JsonObject args) {
        String sourceId = getString(args, "sourceId");
        String key = getString(args, "key");
        Object isAnime = getIsAnime(args);
        JsonElement valueElem = args.get("value");

        Object actualValue = null;
        if (valueElem != null && !valueElem.isJsonNull()) {
            if (valueElem.isJsonPrimitive()) {
                JsonPrimitive prim = valueElem.getAsJsonPrimitive();
                if (prim.isBoolean()) {
                    actualValue = prim.getAsBoolean();
                } else if (prim.isNumber()) {
                    double d = prim.getAsDouble();
                    if (d == (double) prim.getAsInt()) {
                        actualValue = prim.getAsInt();
                    } else {
                        actualValue = d;
                    }
                } else {
                    actualValue = prim.getAsString();
                }
            } else if (valueElem.isJsonArray()) {
                java.util.Set<String> set = new java.util.HashSet<>();
                for (JsonElement e : valueElem.getAsJsonArray()) {
                    set.add(e.getAsString());
                }
                actualValue = set;
            } else {
                actualValue = valueElem.toString();
            }
        }

        try {
            String result = com.anymex.desktop.AniyomiSourceMethods.INSTANCE.savePreference(sourceId, key, actualValue, isAnime);
            return "success".equals(result) ? "true" : "false";
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] aniyomiSavePreference error: " + t.getMessage());
            return "false";
        }
    }

    // =======================================================================
    //  CloudStream helper handlers
    // =======================================================================

    private static String handleCsGetRegisteredProviders() {
        try {
            JsonArray arr = new JsonArray();
            for (Map.Entry<String, ?> entry : com.anymex.desktop.cloudstream.CloudStreamExtensionLoader.INSTANCE.getLoadedMap().entrySet()) {
                com.lagradost.cloudstream3.MainAPI api = (com.lagradost.cloudstream3.MainAPI) entry.getValue();
                JsonObject obj = new JsonObject();
                obj.addProperty("id", entry.getKey());
                obj.addProperty("name", api.getName());
                obj.addProperty("lang", api.getLang());
                obj.addProperty("baseUrl", api.getMainUrl());
                arr.add(obj);
            }
            return gson.toJson(arr);
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] csGetRegisteredProviders error: " + t.getMessage());
            return "[]";
        }
    }

    private static String handleCsGetExtensionSettings(JsonObject args) {
        // CloudStream MainAPI doesn't have a standard preference screen mechanism
        // like Aniyomi. Return empty array.
        return "[]";
    }

    private static String handleCsSetExtensionSettings(JsonObject args) {
        // CloudStream settings are not persisted via this bridge on desktop.
        // Return success for compatibility.
        return gson.toJson(Map.of("success", true));
    }

    // =======================================================================
    //  Global method handlers
    // =======================================================================

    private static String handleCancelRequest(JsonObject args) {
        String targetId = getString(args, "id");
        if (targetId.isEmpty()) {
            return errorJson("cancelRequest requires 'id' parameter");
        }

        // Remove tracked request
        activeJobs.remove(targetId);

        // Try to cancel OkHttp calls with matching tag
        try {
            // Cancel not supported via Injekt on iOS - no-op
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] Error cancelling OkHttp calls: " + t.getMessage());
        }

        System.err.println("[IosExtensionLoader] Cancelled request: " + targetId);
        return gson.toJson(Map.of("cancelled", true));
    }

    private static String handleSetCookies(JsonObject args) {
        String url = getString(args, "url");
        String cookieString = getString(args, "cookieString");

        if (url.isEmpty() || cookieString.isEmpty()) {
            return errorJson("url and cookieString are required");
        }

        try {
            // Store in our local map
            cookieStore.put(url, cookieString);

            // Also inject into the JVM cookie store used by OkHttp
            URI uri = new URI(url);
            String[] cookies = cookieString.split(";");
            int count = 0;
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.isEmpty()) continue;
                List<HttpCookie> parsed = HttpCookie.parse("Set-Cookie: " + cookie);
                if (!parsed.isEmpty()) {
                    eu.kanade.tachiyomi.network.NetworkHelper.Companion.getSharedCookieManager().getCookieStore().add(uri, parsed.get(0));
                    count++;
                }
            }
            System.err.println("[IosExtensionLoader] setCookies: injected " + count + " cookie(s) for " + url);
            return "\"ok\"";
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] setCookies error: " + t.getMessage());
            return errorJson("setCookies failed: " + t.getMessage());
        }
    }

    private static String handleSetUserAgent(JsonObject args) {
        String url = getString(args, "url");
        String userAgent = getString(args, "userAgent");

        if (url.isEmpty() || userAgent.isEmpty()) {
            return errorJson("url and userAgent are required");
        }

        try {
            String host = new URI(url).getHost();
            if (host == null || host.isEmpty()) host = url;
            userAgentStore.put(host, userAgent);
            System.setProperty("anymex.ua." + host, userAgent);
            System.err.println("[IosExtensionLoader] setUserAgent: stored UA for host=" + host);
            return "\"ok\"";
        } catch (Throwable t) {
            System.err.println("[IosExtensionLoader] setUserAgent error: " + t.getMessage());
            return errorJson("setUserAgent failed: " + t.getMessage());
        }
    }

    private static String handleCancel(JsonObject args) {
        // Cancel is the same as cancelRequest but with potentially different arg layout
        String targetId = getString(args, "id");
        if (!targetId.isEmpty()) {
            activeJobs.remove(targetId);
            System.err.println("[IosExtensionLoader] Cancelled: " + targetId);
        }
        return "\"ok\"";
    }

    // =======================================================================
    //  Filter serialization helpers
    // =======================================================================

    private static JsonObject serializeAnimeFilter(AnimeFilter<?> filter) {
        JsonObject obj = new JsonObject();
        obj.addProperty("name", filter.getName());

        if (filter instanceof AnimeFilter.Header) {
            obj.addProperty("type", "Header");
        } else if (filter instanceof AnimeFilter.Separator) {
            obj.addProperty("type", "Separator");
        } else if (filter instanceof AnimeFilter.Text) {
            obj.addProperty("type", "Text");
            obj.addProperty("state", (String) filter.getState());
        } else if (filter instanceof AnimeFilter.CheckBox) {
            obj.addProperty("type", "CheckBox");
            obj.addProperty("state", (Boolean) filter.getState());
        } else if (filter instanceof AnimeFilter.TriState) {
            obj.addProperty("type", "TriState");
            obj.addProperty("state", (Integer) filter.getState());
        } else if (filter instanceof AnimeFilter.Select) {
            AnimeFilter.Select<?> select = (AnimeFilter.Select<?>) filter;
            obj.addProperty("type", "Select");
            obj.addProperty("state", (Integer) select.getState());
            JsonArray vals = new JsonArray();
            for (Object v : select.getValues()) {
                vals.add(v != null ? v.toString() : "");
            }
            obj.add("values", vals);
        } else if (filter instanceof AnimeFilter.Sort) {
            AnimeFilter.Sort sort = (AnimeFilter.Sort) filter;
            obj.addProperty("type", "Sort");
            JsonArray vals = new JsonArray();
            for (String v : sort.getValues()) {
                vals.add(v);
            }
            obj.add("values", vals);
            Object state = sort.getState();
            if (state != null && state instanceof AnimeFilter.Sort.Selection) {
                AnimeFilter.Sort.Selection sel = (AnimeFilter.Sort.Selection) state;
                JsonObject stateObj = new JsonObject();
                stateObj.addProperty("index", sel.getIndex());
                stateObj.addProperty("ascending", sel.getAscending());
                obj.add("state", stateObj);
            } else {
                obj.add("state", JsonNull.INSTANCE);
            }
        } else if (filter instanceof AnimeFilter.Group) {
            obj.addProperty("type", "Group");
            JsonArray subFilters = new JsonArray();
            Object state = filter.getState();
            if (state instanceof List) {
                for (Object sub : (List<?>) state) {
                    if (sub instanceof AnimeFilter) {
                        subFilters.add(serializeAnimeFilter((AnimeFilter<?>) sub));
                    }
                }
            }
            obj.add("state", subFilters);
        } else {
            obj.addProperty("type", "Unknown");
        }

        return obj;
    }

    private static JsonObject serializeMangaFilter(Filter<?> filter) {
        JsonObject obj = new JsonObject();
        obj.addProperty("name", filter.getName());

        if (filter instanceof Filter.Header) {
            obj.addProperty("type", "Header");
        } else if (filter instanceof Filter.Separator) {
            obj.addProperty("type", "Separator");
        } else if (filter instanceof Filter.Text) {
            obj.addProperty("type", "Text");
            obj.addProperty("state", (String) filter.getState());
        } else if (filter instanceof Filter.CheckBox) {
            obj.addProperty("type", "CheckBox");
            obj.addProperty("state", (Boolean) filter.getState());
        } else if (filter instanceof Filter.TriState) {
            obj.addProperty("type", "TriState");
            obj.addProperty("state", (Integer) filter.getState());
        } else if (filter instanceof Filter.Select) {
            Filter.Select<?> select = (Filter.Select<?>) filter;
            obj.addProperty("type", "Select");
            obj.addProperty("state", (Integer) select.getState());
            JsonArray vals = new JsonArray();
            for (Object v : select.getValues()) {
                vals.add(v != null ? v.toString() : "");
            }
            obj.add("values", vals);
        } else if (filter instanceof Filter.Sort) {
            Filter.Sort sort = (Filter.Sort) filter;
            obj.addProperty("type", "Sort");
            JsonArray vals = new JsonArray();
            for (String v : sort.getValues()) {
                vals.add(v);
            }
            obj.add("values", vals);
            Object state = sort.getState();
            if (state != null && state instanceof Filter.Sort.Selection) {
                Filter.Sort.Selection sel = (Filter.Sort.Selection) state;
                JsonObject stateObj = new JsonObject();
                stateObj.addProperty("index", sel.getIndex());
                stateObj.addProperty("ascending", sel.getAscending());
                obj.add("state", stateObj);
            } else {
                obj.add("state", JsonNull.INSTANCE);
            }
        } else if (filter instanceof Filter.Group) {
            obj.addProperty("type", "Group");
            JsonArray subFilters = new JsonArray();
            Object state = filter.getState();
            if (state instanceof List) {
                for (Object sub : (List<?>) state) {
                    if (sub instanceof Filter) {
                        subFilters.add(serializeMangaFilter((Filter<?>) sub));
                    }
                }
            }
            obj.add("state", subFilters);
        } else {
            obj.addProperty("type", "Unknown");
        }

        return obj;
    }

    // =======================================================================
    //  Suspend function runner — bridges Java → Kotlin coroutines
    // =======================================================================

    /**
     * Run a Kotlin suspend function from Java using runBlocking.
     * The lambda receives a CoroutineScope and a Continuation, which is exactly
     * the calling convention for Kotlin suspend functions compiled to JVM bytecode.
     */
    @SuppressWarnings("unchecked")
    private static String runSuspend(JsonObject args, Function2<CoroutineScope, Continuation<? super String>, Object> block) {
        try {
            return (String) BuildersKt.runBlocking(
                    EmptyCoroutineContext.INSTANCE,
                    (Function2<CoroutineScope, Continuation<Object>, Object>) (scope, cont) -> block.invoke(scope, (Continuation) cont)
            );
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return errorJson("Interrupted: " + e.getMessage());
        }
    }

    // =======================================================================
    //  JSON argument helpers
    // =======================================================================

    private static String getString(JsonObject obj, String key) {
        JsonElement elem = obj.get(key);
        if (elem == null || elem.isJsonNull()) return "";
        if (elem.isJsonPrimitive() && elem.getAsJsonPrimitive().isString()) {
            return elem.getAsJsonPrimitive().getAsString();
        }
        return elem.toString();
    }

    private static int getInt(JsonObject obj, String key, int defaultVal) {
        JsonElement elem = obj.get(key);
        if (elem == null || elem.isJsonNull()) return defaultVal;
        if (elem.isJsonPrimitive() && elem.getAsJsonPrimitive().isNumber()) {
            return elem.getAsJsonPrimitive().getAsInt();
        }
        return defaultVal;
    }

    private static boolean getBoolean(JsonObject obj, String key, boolean defaultVal) {
        JsonElement elem = obj.get(key);
        if (elem == null || elem.isJsonNull()) return defaultVal;
        if (elem.isJsonPrimitive() && elem.getAsJsonPrimitive().isBoolean()) {
            return elem.getAsJsonPrimitive().getAsBoolean();
        }
        return defaultVal;
    }

    /**
     * Get the isAnime parameter. The Kotlin side accepts Any (Boolean, String, or any Object)
     * and resolves it internally. We pass the raw value through.
     */
    private static Object getIsAnime(JsonObject args) {
        JsonElement elem = args.get("isAnime");
        if (elem == null || elem.isJsonNull()) return false;
        if (elem.isJsonPrimitive()) {
            JsonPrimitive prim = elem.getAsJsonPrimitive();
            if (prim.isBoolean()) return prim.getAsBoolean();
            return Boolean.parseBoolean(prim.getAsString());
        }
        return elem.toString();
    }

    private static String errorJson(String message) {
        JsonObject err = new JsonObject();
        err.addProperty("error", message);
        return gson.toJson(err);
    }

    // =======================================================================
    //  Main method — mirrors DesktopExtensionLoader's main() for desktop testing
    // =======================================================================

    /**
     * Desktop test harness. Reads JSON-RPC lines from stdin, dispatches via
     * callMethod, and writes JSON responses to stdout.  This is the same pattern
     * used by {@code com.anymex.desktop.DesktopExtensionLoaderKt.main}.
     * <p>
     * Each line must be a JSON object with at least a "method" field.
     * Optional "id" field is echoed back in the response for request tracking.
     */
    @SuppressWarnings("unchecked")
    public static void main(String[] argsArr) {
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, java.nio.charset.StandardCharsets.UTF_8));
        PrintStream originalOut = System.out;
        PrintStream cleanOut = new PrintStream(originalOut, true, java.nio.charset.StandardCharsets.UTF_8);

        // Redirect System.out to stderr so only our JSON responses go to stdout
        System.setOut(new PrintStream(System.err, true, java.nio.charset.StandardCharsets.UTF_8));

        System.err.println("[IosExtensionLoader] Sidecar process started (main mode)");

        // Clear page cache
        try {
            java.io.File cacheDir = new java.io.File(System.getProperty("user.home"), ".anymex/cache/manga_pages_cache");
            if (cacheDir.exists()) deleteRecursive(cacheDir);
        } catch (Exception ignored) {}

        System.err.println("[IosExtensionLoader] All stdout redirected to stderr for IPC safety.");

        while (true) {
            String line;
            try {
                line = reader.readLine();
            } catch (Exception e) {
                break;
            }
            if (line == null || line.isBlank()) continue;

            try {
                JsonObject request = gson.fromJson(line, JsonObject.class);
                if (request == null) continue;

                String method = getString(request, "method");
                String requestId = getString(request, "id");

                if (method.isEmpty()) continue;

                // Extract args object if present
                JsonObject methodArgs = request.getAsJsonObject("args");
                if (methodArgs == null) methodArgs = new JsonObject();

                // Handle cancel specially (no response needed)
                if ("cancel".equals(method)) {
                    String targetId = getString(methodArgs, "id");
                    if (!targetId.isEmpty()) {
                        activeJobs.remove(targetId);
                        try {
                            // Cancel not supported via Injekt on iOS - no-op
                        } catch (Exception e) {
                            System.err.println("[IosExtensionLoader] Error cancelling OkHttp calls: " + e.getMessage());
                        }
                        System.err.println("[IosExtensionLoader] Cancelled request: " + targetId);
                    }
                    continue;
                }

                if (!requestId.isEmpty()) {
                    // Track this request ID for potential cancellation
                    activeJobs.put(requestId, requestId);
                }

                String resultData = callMethod(method, methodArgs.toString());

                if (!requestId.isEmpty()) {
                    JsonObject responseObj = new JsonObject();
                    responseObj.addProperty("id", requestId);

                    // Try to parse resultData as JSON and nest it under "data"
                    try {
                        JsonElement parsed = gson.fromJson(resultData, JsonElement.class);
                        responseObj.add("data", parsed);
                    } catch (Exception e) {
                        // If it's not valid JSON, wrap as a string primitive
                        responseObj.addProperty("data", resultData);
                    }

                    synchronized (cleanOut) {
                        cleanOut.println(gson.toJson(responseObj));
                    }
                    activeJobs.remove(requestId);
                } else {
                    synchronized (cleanOut) {
                        cleanOut.println(resultData);
                    }
                }
            } catch (Throwable t) {
                System.err.println("[IosExtensionLoader] Error processing line: " + line);
                t.printStackTrace();
                JsonObject errorResponse = new JsonObject();
                errorResponse.addProperty("error", t.getMessage() != null ? t.getMessage() : t.toString());
                synchronized (cleanOut) {
                    cleanOut.println(gson.toJson(errorResponse));
                }
            }
        }
    }

    private static void deleteRecursive(java.io.File file) {
        if (file.isDirectory()) {
            java.io.File[] children = file.listFiles();
            if (children != null) {
                for (java.io.File child : children) {
                    deleteRecursive(child);
                }
            }
        }
        file.delete();
    }
}
